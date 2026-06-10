/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager_dio/flutter_cache_manager_dio.dart';

import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/illust_cacher.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

const ImageHost = "i.pximg.net";
const ImageCatHost = "i.pixiv.re";
const ImageSHost = "s.pximg.net";

// 注意，stable的http_interceptor这里是无效的，因为实现send是todo
// 实现CacheManager和混入ImageCacheManager缺一不可
// 如果你恰好看到这个实现方法实例，且对你有些帮助或者启发：
// 听一首Mili-Salt, Pepper, Birds, And the Thought Police吧 🎵

CacheManager? pixivCacheManager;

class PixEzCacheHeaderData {
  final String key;
  final IllustQuality quality;

  PixEzCacheHeaderData({required this.key, required this.quality});
}

class PixivImage extends StatefulWidget {
  final String url;
  final Widget? placeWidget;
  final bool fade;
  final BoxFit? fit;
  final bool? enableMemoryCache;
  final double? height;
  final double? width;
  final String? host;
  final PixEzCacheHeaderData? cacheHeaderData;
  final String? errorHint; // 加载失败时显示的元信息（如标题/页码）

  PixivImage(
    this.url, {
    this.placeWidget,
    this.fade = true,
    this.fit,
    this.enableMemoryCache,
    this.height,
    this.host,
    this.width,
    this.cacheHeaderData,
    this.errorHint,
  });

  @override
  _PixivImageState createState() => _PixivImageState();

  static Dio? _cacheDio;

  static Future<void> generatePixivCache() async {
    // 独立版本：自定义图床走系统默认HTTP，直连Pixiv走兼容模式
    final imageUseCompat = userSetting.networkMode != NetworkMode.standard &&
                           userSetting.pictureSource == ImageHost;
    final client = await r.RhttpCompatibleClient.createSync(
      settings: imageUseCompat ? PixezNetworkSettings.compatible() : null,
    );
    final existing = _cacheDio;
    if (existing != null) {
      existing.httpClientAdapter = ConversionLayerAdapter(client);
      return;
    }
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: 15),
      receiveTimeout: Duration(seconds: 30),
    ));
    dio.interceptors.add(
      PixivImageSourceInterceptor(
        networkMode: () => userSetting.networkMode,
        pictureSource: () => userSetting.pictureSource,
      ),
    );
    dio.httpClientAdapter = ConversionLayerAdapter(client);
    _cacheDio = dio;
    // 自定义缓存：500 对象上限，避免浏览长列表时频繁驱逐
    pixivCacheManager = CacheManager(Config(
      'dioCache',
      fileService: DioHttpFileService(dio),
      maxNrOfCacheObjects: 500,
      stalePeriod: Duration(days: 30),
    ));
    // 预热 Worker：fire-and-forget 减少首图冷启动延迟
    _warmUpWorker(dio);
  }

  /// 发送一个 HEAD 请求预热 Worker isolate
  static void _warmUpWorker(Dio dio) {
    if (userSetting.pictureSource == ImageHost) return;
    final source = userSetting.pictureSource;
    if (source == null || source.isEmpty) return;
    final warmUrl = source.startsWith('http') ? source : 'https://$source';
    dio.head(warmUrl).then((_) {}).catchError((_) {});
  }
}

class PixivImageInterceptor extends Interceptor {
  static String cacheKey = 'cache_key';
  static String cacheQualityKey = 'cache_quality';
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    super.onRequest(options, handler);
    if (options.headers.containsKey(cacheKey)) {
      final key = options.headers[cacheKey] as String?;
      final quality = options.headers[cacheQualityKey] as String?;
      options.headers.remove(cacheKey);
      if (key != null && quality != null) {
        options.extra[cacheKey] = key;
        options.extra[cacheQualityKey] = quality;
      }
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    super.onResponse(response, handler);
    final extra = response.extra;
    if (extra.containsKey(cacheKey)) {
      final key = extra[cacheKey] as String?;
      final quality = int.tryParse(extra[cacheQualityKey] as String? ?? '');
      if (key != null && quality != null) {
        IllustCacher.saveCacheIllustQuality(
          key,
          IllustQualityExtension.fromValue(quality),
          response.realUri.toString(),
        );
      }
    }
    handler.next(response);
  }
}

class _PixivImageState extends State<PixivImage> {
  late String url;
  bool already = false;
  bool? enableMemoryCache;
  double? width;
  double? height;
  BoxFit? fit;
  bool fade = true;
  Widget? placeWidget;
  int _retryCount = 0;
  String? _lastKey;
  Uint8List? _cachedBytes; // 方案 B: 从本地缓存回退的图片字节
  bool _fromCache = false;

  @override
  void initState() {
    url = widget.url;
    enableMemoryCache = widget.enableMemoryCache ?? true;
    width = widget.width;
    height = widget.height;
    fit = widget.fit;
    fade = widget.fade;
    placeWidget = widget.placeWidget;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant PixivImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryCount = 0;
      _cachedBytes = null;
      _fromCache = false;
      setState(() {
        url = widget.url;
        width = widget.width;
        height = widget.height;
      });
    }
  }

  /// 方案 B: 网络失败后依次尝试本地缓存 → 直接下载
  Future<void> _tryLoadFallback(String sourceUrl) async {
    if (_cachedBytes != null) return;
    try {
      final resolvedUrl = PixivImageSource.resolve(
        sourceUrl,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      // 1) 尝试本地文件缓存
      final fileInfo = await pixivCacheManager?.getFileFromCache(resolvedUrl);
      if (fileInfo != null && mounted) {
        final bytes = fileInfo.file.readAsBytesSync();
        if (bytes.isNotEmpty) {
          setState(() {
            _cachedBytes = bytes;
            _fromCache = true;
          });
          return;
        }
      }
      // 2) 缓存未命中，直接用 Dio 下载（绕过 CachedNetworkImage 管线）
      await _directDownload(resolvedUrl);
    } catch (e) {
      print('_tryLoadFallback error: $e');
    }
  }

  /// 直接用 Dio 下载图片字节，绕过 CacheManager/CachedNetworkImage 管线
  Future<void> _directDownload(String downloadUrl) async {
    try {
      final dio = await _getImageDio();
      final resp = await dio.get<List<int>>(
        downloadUrl,
        options: Options(
          headers: {...Hoster.header(url: downloadUrl)},
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      if (resp.data != null && resp.data!.isNotEmpty && mounted) {
        setState(() {
          _cachedBytes = Uint8List.fromList(resp.data!);
          _fromCache = false;
        });
      }
    } catch (e) {
      print('_directDownload error: $e');
    }
  }

  /// 获取图片专用 Dio（复用 PixivImage._cacheDio，避免创建多余的 rhttp client）
  Future<Dio> _getImageDio() async {
    if (PixivImage._cacheDio != null) return PixivImage._cacheDio!;
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
  }

  void _scheduleRetry() {
    if (_retryCount >= 3) return;
    _retryCount++;
    final delay = Duration(seconds: 2 << (_retryCount - 1));
    final currentKey = url;
    _lastKey = currentKey;
    Future.delayed(delay, () {
      if (mounted && _lastKey == currentKey) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentKey = url;
    if (_lastKey != currentKey) { _lastKey = currentKey; }

    // 方案 B: 如果已从缓存加载，直接显示
    if (_cachedBytes != null) {
      return Container(
        width: width,
        height: height,
        color: Colors.grey.shade200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(_cachedBytes!, fit: fit ?? BoxFit.fitWidth, width: width, height: height),
            // 缓存标记
            Positioned(
              bottom: 2, right: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('缓存', style: TextStyle(color: Colors.white, fontSize: 9)),
              ),
            ),
          ],
        ),
      );
    }

    return CachedNetworkImage(
      key: ValueKey('$_retryCount'),
      placeholder: (context, url) =>
          widget.placeWidget ?? Container(height: height),
      errorWidget: (context, url, error) {
        _scheduleRetry();
        _tryLoadFallback(url); // 方案 B: 网络失败→缓存→直接下载
        final fileName = Uri.tryParse(url)?.pathSegments.isNotEmpty == true
            ? Uri.parse(url).pathSegments.last
            : '';
        final hint = widget.errorHint ?? fileName;
        return Container(
          height: height,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hint.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(hint,
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                TextButton(
                  onPressed: () {
                    _retryCount = 0;
                    _cachedBytes = null; // 重置缓存，强制重试网络
                    setState(() {});
                  },
                  child: Text(":("),
                ),
              ],
            ),
          ),
        );
      },
      fadeOutDuration: widget.fade ? const Duration(milliseconds: 1000) : null,
      imageUrl: url,
      cacheManager: pixivCacheManager,
      height: height,
      width: width,
      fit: fit ?? BoxFit.fitWidth,
      httpHeaders: {...Hoster.header(url: url)},
    );
  }
}

class PixivProvider {
  static ImageProvider url(String url, {String? preUrl}) {
    return CachedNetworkImageProvider(
      url,
      headers: Hoster.header(url: preUrl),
      cacheManager: pixivCacheManager,
    );
  }
}

// class RubyProvider extends ImageProvider{
//   @override
//   ImageStreamCompleter load(Object key, Future<Codec> Function(Uint8List bytes, {bool allowUpscaling, int cacheHeight, int cacheWidth}) decode) {
//     // TODO: implement load
//     throw UnimplementedError();
//   }
//
//   @override
//   Future<Object> obtainKey(ImageConfiguration configuration) {
//     // TODO: implement obtainKey
//     throw UnimplementedError();
//   }
// }
