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

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager_dio/flutter_cache_manager_dio.dart';

import 'package:pixez/constants.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/illust_cacher.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;

// 主机常量定义在 constants.dart（消除 hoster ↔ pixiv_image 循环依赖），
// 经此 export 保持旧引用（网络设置页等）无需改动
export 'package:pixez/constants.dart' show ImageHost, ImageCatHost, ImageSHost;

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
  /// 瀑布流中的位置索引（可为 null 表示不参与优先级协调）
  final int? priorityIndex;

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
    this.priorityIndex,
  });

  @override
  _PixivImageState createState() => _PixivImageState();

  static Dio? _cacheDio;

  static Future<void> generatePixivCache() async {
    final client = await r.RhttpCompatibleClient.createSync(
      settings: PixezNetworkSettings.forImages(
        userSetting.pictureSource,
        userSetting.networkMode,
      ),
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

  // 优先级协调状态
  bool _canLoad = true;
  bool _slotReleased = false;
  String? _registeredUrl;
  Timer? _slotTimer; // 槽位超时保护
  // 连续槽位超时计数：网络故障时避免无限"排队→超时→重排"循环
  int _slotTimeoutCount = 0;
  static const int _maxSlotTimeouts = 3;
  // 已检查过文件缓存的 url（去重：同一 url 只查一次，避免频繁磁盘查询）
  String? _cacheCheckedUrl;
  // 预解码完成的位图（RawImage 直显，零解码窗口）
  ui.Image? _decodedImage;

  // 协调器实例：initState 阶段（Element active）从列表作用域解析并缓存。
  // 不能惰性初始化或每次用 getter 查 context——dispose 阶段 Element 已
  // defunct，祖先查找会抛 "Looking up a deactivated widget's ancestor is unsafe"
  late final ImageLoadCoordinator _coordinator;

  @override
  void initState() {
    url = widget.url;
    enableMemoryCache = widget.enableMemoryCache ?? true;
    width = widget.width;
    height = widget.height;
    fit = widget.fit;
    fade = widget.fade;
    placeWidget = widget.placeWidget;
    // initState 阶段解析协调器实例（此时 Element active，可安全祖先查找），
    // 供 dispose 等阶段使用缓存引用
    _coordinator = ImageLoadCoordinator.of(context);
    super.initState();

    // 如果参与了优先级协调，立即注册槽位（同步，无帧延迟）
    if (widget.priorityIndex != null) {
      _canLoad = false;
      _registeredUrl = widget.url;
      _requestSlot();
    }
  }

  /// 图片加载完成后预解码文件缓存字节，完成后用 RawImage 显示。
  ///
  /// 为什么需要：返回页面时 TickerMode 恢复 → CachedNetworkImage 内部
  /// OctoImage 的 Image 组件重新 resolve。Image 组件在 `_updateSourceStream`
  /// 中（gaplessPlayback 默认 false）会强制清空 _imageInfo；ImageCache
  /// 命中（同一 completer）则立即恢复无感知，未命中（被其他页面 LRU
  /// 逐出）则显示 placeholder 直到重新加载完成 → 白屏。
  /// 本方案在图片加载完成时就后台解码，随后无感切换到 RawImage 分支
  /// （同图切换，视觉无变化）——此后任何时刻返回，位图必然已就绪，
  /// OctoImage 已不在树中，其清空/重载机制完全不涉及。
  Future<void> _preDecodeAfterLoad(String targetUrl) async {
    // 已成功预解码过的 url 跳过（去重）；失败时不置位，网络重试加载
    // 成功后允许再次尝试（缓存可能已被其他页面写入）
    if (targetUrl.isEmpty ||
        _decodedImage != null ||
        _cacheCheckedUrl == targetUrl) {
      return;
    }
    // 在异步操作前取显示宽度与缩放（await 后 context 可能已 unmount，
    // 此时 MediaQuery.of 在 debug 下会抛错）
    final double scale = MediaQuery.of(context).devicePixelRatio;
    final double? displayWidth = width;
    final int? targetWidth =
        displayWidth == null ? null : (displayWidth * scale).round();
    try {
      final resolvedUrl = PixivImageSource.resolve(
        targetUrl,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      final fileInfo = await pixivCacheManager?.getFileFromCache(resolvedUrl);
      // 代际校验：检查期间 url 可能又变了（快速切换）
      if (fileInfo != null &&
          mounted &&
          url == targetUrl &&
          _decodedImage == null) {
        // 异步读取，避免同步 IO 阻塞 UI 线程（原图可达 5~20MB）
        final bytes = await fileInfo.file.readAsBytes();
        if (bytes.isNotEmpty) {
          final codec =
              await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
          try {
            final frame = await codec.getNextFrame();
            final image = frame.image;
            if (mounted && url == targetUrl && _decodedImage == null) {
              _cacheCheckedUrl = targetUrl; // 仅成功后置位，失败允许重试
              setState(() => _decodedImage = image);
            } else {
              image.dispose();
            }
          } finally {
            codec.dispose();
          }
        }
      }
    } catch (_) {
      // 解码失败：保持现有加载流程（不置位，允许后续重试）
    }
  }

  @override
  void didUpdateWidget(covariant PixivImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      // 取消旧 URL 的协调器注册
      if (oldWidget.url.isNotEmpty) {
        _coordinator.cancel(oldWidget.url);
      }
      _retryCount = 0;
      _cachedBytes = null;
      _fromCache = false;
      _slotReleased = false;
      _slotTimeoutCount = 0;
      _cacheCheckedUrl = null;
      _decodedImage?.dispose();
      _decodedImage = null;
      setState(() {
        url = widget.url;
        width = widget.width;
        height = widget.height;
      });
      // 切换图片时主动检查文件缓存：命中则直接 Image.memory 显示，
      // 完全绕过 CachedNetworkImage（避免其 url 变化时 placeholder
      // 必然短暂显示 → 加载动画闪烁）
      _checkCacheOnUrlChange(widget.url);
      // 重新请求槽位
      if (widget.priorityIndex != null) {
        _canLoad = false;
        _registeredUrl = widget.url;
        _requestSlot();
      }
    }
  }

  /// 切换图片时的缓存检查：命中即用本地字节直显（零动画、零 placeholder）
  Future<void> _checkCacheOnUrlChange(String targetUrl) async {
    if (targetUrl.isEmpty || _cachedBytes != null) return;
    try {
      final resolvedUrl = PixivImageSource.resolve(
        targetUrl,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      final fileInfo = await pixivCacheManager?.getFileFromCache(resolvedUrl);
      // 代际校验：检查期间 url 可能又变了（快速连续切换），
      // 过期回调填入的字节会导致显示错误图片
      if (fileInfo != null && mounted && url == targetUrl && _cachedBytes == null) {
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节
        if (bytes.isNotEmpty &&
            mounted &&
            url == targetUrl &&
            _cachedBytes == null) {
          setState(() {
            _cachedBytes = Uint8List.fromList(bytes);
            _fromCache = true;
          });
        }
      }
    } catch (_) {
      // 缓存检查失败：走正常加载流程
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
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节
        if (bytes.isNotEmpty &&
            mounted &&
            url == sourceUrl &&
            _cachedBytes == null) {
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

  /// 向协调器请求加载槽位（同步，无延迟）。
  /// 前 maxConcurrent 个直接放行，超出则按优先级排队。
  /// 同时在后台检查文件缓存，若排队中命中缓存则直接显示。
  void _requestSlot() {
    final targetUrl = widget.url;
    if (targetUrl.isEmpty) return;

    final granted = _coordinator.register(
      targetUrl,
      widget.priorityIndex ?? 0,
      _onSlotReady,
    );
    if (granted) {
      _slotReleased = false;
      _slotTimeoutCount = 0;
      _startSlotTimer();
      if (mounted) setState(() => _canLoad = true);
    }

    // 后台检查缓存：如果在排队中且缓存命中，绕过协调器立即显示
    _tryCacheBypass(targetUrl);
  }

  /// 启动槽位超时保护定时器
  void _startSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = Timer(const Duration(seconds: 30), _onSlotTimeout);
  }

  /// 槽位超时：释放当前槽位并强制重试。
  /// 连续超时达到上限后停止重排，改走默认 CachedNetworkImage 加载流程，
  /// 网络故障时由 errorWidget/手动重试接管，避免无限"排队→超时→重排"循环。
  void _onSlotTimeout() {
    if (!mounted) return;
    _coordinator.release(widget.url);
    _slotReleased = true;
    _slotTimer = null;
    _slotTimeoutCount++;
    if (_slotTimeoutCount >= _maxSlotTimeouts) {
      // 达到连续超时上限：放行默认加载流程（失败时显示错误提示与重试按钮）
      _canLoad = true;
      setState(() {});
      return;
    }
    // 重置状态，重新请求槽位
    _canLoad = false;
    _retryCount = 0;
    _cachedBytes = null;
    if (mounted) {
      setState(() {});
      _requestSlot();
    }
  }

  /// 后台检查文件缓存，命中则立即显示并释放排队槽位
  Future<void> _tryCacheBypass(String targetUrl) async {
    // 已经获得加载许可，无需绕过
    if (_canLoad) return;
    try {
      final resolvedUrl = PixivImageSource.resolve(
        targetUrl,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      final fileInfo = await pixivCacheManager?.getFileFromCache(resolvedUrl);
      if (fileInfo != null && mounted && !_canLoad) {
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节
        if (bytes.isNotEmpty &&
            mounted &&
            url == targetUrl &&
            _cachedBytes == null) {
          // 缓存命中：直接填入 _cachedBytes，build 走"已缓存"分支
          //（Image.memory 直接显示，完全绕过 CachedNetworkImage 管线）
          _coordinator.cancel(targetUrl);
          setState(() {
            _cachedBytes = Uint8List.fromList(bytes);
            _fromCache = true;
          });
        }
      }
    } catch (_) {
      // 缓存检查失败，继续排队等待
    }
  }

  /// 协调器分配槽位后的回调
  void _onSlotReady() {
    if (!mounted) return;
    if (_registeredUrl != widget.url) return;
    _slotReleased = false;
    _slotTimeoutCount = 0;
    _startSlotTimer();
    setState(() => _canLoad = true);
  }

  /// 释放槽位（CachedNetworkImage 加载完成或失败后）
  void _releaseSlot() {
    if (_slotReleased) return;
    _slotReleased = true;
    _slotTimer?.cancel();
    _slotTimer = null;
    _coordinator.release(widget.url);
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

    // 已预解码完成：RawImage 直显（零解码窗口，免疫返回时重新加载）
    if (_decodedImage != null) {
      return Container(
        width: width,
        height: height,
        color: Colors.grey.shade200,
        child: RawImage(
          image: _decodedImage,
          fit: fit ?? BoxFit.fitWidth,
          width: width,
          height: height,
        ),
      );
    }

    // 方案 B: 如果已从缓存加载，直接显示（不受优先级协调影响）
    if (_cachedBytes != null) {
      return Container(
        width: width,
        height: height,
        color: Colors.grey.shade200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 解码期间先显示占位（缩略图），避免大图重新解码时空白
            if (placeWidget != null) placeWidget!,
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

    // 优先级协调：尚未获得槽位时显示占位符
    if (!_canLoad) {
      return widget.placeWidget ?? Container(height: height);
    }

    final size = min(min(width ?? 60, height ?? 60), 60.0);
    return CachedNetworkImage(
      key: ValueKey('$_retryCount'),
      placeholder: (context, url) =>
          widget.placeWidget ??
          // 加载超过 200ms 才显示进度环，避免快速加载（缓存命中）时的闪烁
          _DelayedIndicator(
            url: url,
            child: Container(
              height: height,
              child: Center(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: const Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: const CircularProgressIndicator(),
                  ),
                ),
              ),
            ),
          ),
      imageBuilder: (context, imageProvider) {
        _releaseSlot();
        // 加载完成：后台预解码文件缓存，完成后 RawImage 直显，
        // 返回页面时零窗口（免疫 ImageCache 逐出导致的重新加载白屏）。
        // 去重与失败重试由 _preDecodeAfterLoad 内部管理（仅成功置位）
        _preDecodeAfterLoad(widget.url);
        return Image(
          image: imageProvider,
          fit: fit ?? BoxFit.fitWidth,
          width: width,
          height: height,
        );
      },
      errorWidget: (context, url, error) {
        _releaseSlot();
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
      // fadeOut 期间 CachedNetworkImage 会显示 placeholder（旧图切换时），
      // 缩短到 150ms 减少加载动画暴露窗口；缓存命中走方案 B 完全无此问题
      fadeOutDuration: widget.fade ? const Duration(milliseconds: 150) : null,
      imageUrl: url,
      cacheManager: pixivCacheManager,
      height: height,
      width: width,
      fit: fit ?? BoxFit.fitWidth,
      httpHeaders: {...Hoster.header(url: url)},
    );
  }

  @override
  void dispose() {
    _slotTimer?.cancel();
    _decodedImage?.dispose();
    _coordinator.cancel(widget.url);
    super.dispose();
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

/// 延迟显示加载指示器：加载在 [delay] 内完成则不显示（组件被替换后
/// 计时器回调不再生效），避免缓存命中/快速加载时的进度环闪烁。
/// 父组件 url 变化（图片已加载完成）时立即隐藏，避免"图片已显示但
/// 动画仍持续"的问题。
class _DelayedIndicator extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final String? url;

  const _DelayedIndicator({
    required this.child,
    this.delay = const Duration(milliseconds: 200),
    this.url,
  });

  @override
  State<_DelayedIndicator> createState() => _DelayedIndicatorState();
}

class _DelayedIndicatorState extends State<_DelayedIndicator> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void didUpdateWidget(covariant _DelayedIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // url 变化 = 切换图片（CachedNetworkImage 重新加载）：
    // 立即隐藏进度环，并重新计时（新 url 慢加载时仍会显示指示器）
    if (widget.url != null && widget.url != oldWidget.url) {
      _timer?.cancel();
      if (_visible) setState(() => _visible = false);
      _timer = Timer(widget.delay, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _visible ? widget.child : const SizedBox.shrink();
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
