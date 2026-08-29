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
  /// 按显示宽度解码（如详情页大图按屏宽 × dpr 限制），
  /// 减小解码内存与 ImageCache 占用；null 表示按原始尺寸解码
  final int? memCacheWidth;

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
    this.memCacheWidth,
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
      final oldAdapter = existing.httpClientAdapter;
      existing.httpClientAdapter = ConversionLayerAdapter(client);
      try {
        oldAdapter.close(force: true);
      } catch (_) {}
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

  /// 预热图床 Worker：GET 根路径（带与图片一致的 referer/UA），
  /// 触发 Cloudflare Worker 冷启动，避免用户浏览首图时才冷启动。
  /// 部分 Worker 的 HEAD 冷启动会挂起 20s+（实测 p.yimovpn.xyz），
  /// 改用 GET；fire-and-forget，失败无影响。
  static void _warmUpWorker(Dio dio) {
    if (userSetting.pictureSource == ImageHost) return;
    final source = userSetting.pictureSource;
    if (source == null || source.isEmpty) return;
    final warmUrl = source.startsWith('http') ? source : 'https://$source';
    dio
        .get<List<int>>(
          warmUrl,
          options: Options(
            headers: Hoster.header(url: warmUrl),
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        .then((_) {})
        .catchError((_) {});
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
  int? memCacheWidth;
  int _retryCount = 0;
  String? _lastKey;
  Uint8List? _cachedBytes; // 方案 B: 从本地缓存回退的图片字节
  // CachedNetworkImage 已渲染出图（当前 url）后，禁止 _cachedBytes 再覆盖：
  // 慢磁盘下缓存字节晚于图片显示完成，切换会出现"图变白再淡入"的闪烁
  bool _imageShown = false;

  // 优先级协调状态
  bool _canLoad = true;
  bool _slotReleased = false;
  String? _registeredUrl;
  Timer? _slotTimer; // 槽位超时保护
  // 连续槽位超时计数：网络故障时避免无限"排队→超时→重排"循环
  int _slotTimeoutCount = 0;
  static const int _maxSlotTimeouts = 3;
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
    memCacheWidth = widget.memCacheWidth;
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

    // 注意：不在 initState 里主动检查文件缓存——那会与 CachedNetworkImage
    // 双通道并行读取同一文件，慢磁盘（手机端）下其回填 _cachedBytes 晚于
    // 图片显示，导致"已显示的图被替换为空白再淡入"的闪烁/白屏竞态。
    // 首次加载交给 CachedNetworkImage 自身（其 file cache 命中已足够快），
    // _checkCacheOnUrlChange 仅用于 url 变化等真正需要快速替换的场景。
  }

  @override
  void didUpdateWidget(covariant PixivImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // memCacheWidth 可能因窗口缩放/屏幕旋转/条目复用而变化：
    // 无条件同步（与 url 无关），避免 State 字段落后导致解码宽度错误
    if (oldWidget.memCacheWidth != widget.memCacheWidth) {
      setState(() => memCacheWidth = widget.memCacheWidth);
    }
    if (oldWidget.url != widget.url) {
      // 取消旧 URL 的协调器注册
      if (oldWidget.url.isNotEmpty) {
        _coordinator.cancel(oldWidget.url);
      }
      _retryCount = 0;
      _cachedBytes = null;      _imageShown = false;
      _slotReleased = false;
      _slotTimeoutCount = 0;
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
      // 缓存 key 是原始 URL：改写发生在 Dio 拦截器层，CacheManager 以传入
      // url 为 key 存储。改查 resolvedUrl 在自定义图床下永远 miss
      final fileInfo = await pixivCacheManager?.getFileFromCache(targetUrl);
      // 代际校验：检查期间 url 可能又变了（快速连续切换），
      // 过期回调填入的字节会导致显示错误图片。
      // 图片已显示（_imageShown）时不覆盖，避免"显示中→空白→淡入"闪烁
      if (fileInfo != null &&
          mounted &&
          url == targetUrl &&
          _cachedBytes == null &&
          !_imageShown) {
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节
        if (bytes.isNotEmpty &&
            mounted &&
            url == targetUrl &&
            _cachedBytes == null &&
            !_imageShown) {
          setState(() {
            _cachedBytes = Uint8List.fromList(bytes);          });
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
      // 1) 尝试本地文件缓存（key 为原始 URL，与 CachedNetworkImage 一致；
      // resolvedUrl 仅用于下方直接下载）
      final fileInfo = await pixivCacheManager?.getFileFromCache(sourceUrl);
      if (fileInfo != null && mounted && !_imageShown) {
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节
        if (bytes.isNotEmpty &&
            mounted &&
            url == sourceUrl &&
            _cachedBytes == null &&
            !_imageShown) {
          setState(() {
            _cachedBytes = bytes;          });
          return;
        }
      }
      // 2) 缓存未命中，直接用 Dio 下载（绕过 CachedNetworkImage 管线）
      await _directDownload(resolvedUrl, checkUrl: sourceUrl);
    } catch (e) {
      print('_tryLoadFallback error: $e');
    }
  }

  /// 直接用 Dio 下载图片字节，绕过 CacheManager/CachedNetworkImage 管线
  ///
  /// [checkUrl] 为发起下载时的原始 URL（非 resolvedUrl），用于代际校验：
  /// 下载期间列表快速滑动复用卡片（url 已变化）时，禁止把上一张卡的
  /// 字节填入当前 State，否则会显示错误图片
  Future<void> _directDownload(String downloadUrl,
      {required String checkUrl}) async {
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
      if (resp.data != null &&
          resp.data!.isNotEmpty &&
          mounted &&
          url == checkUrl) {
        setState(() {
          _cachedBytes = Uint8List.fromList(resp.data!);        });
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
    // 图片已通过本地缓存（_cachedBytes）显示：无需网络槽位。
    // 仅释放占用的槽位，不清除缓存字节——否则已显示的图会突然
    // 消失并重新排队加载（且此分支不构建 CachedNetworkImage，
    // 没有其他 release 来源，槽位只能靠超时释放）
    if (_cachedBytes != null) {
      _releaseSlot();
      return;
    }
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
      // 缓存 key 是原始 URL：改写发生在 Dio 拦截器层，CacheManager 以传入
      // url 为 key 存储。改查 resolvedUrl 在自定义图床下永远 miss
      final fileInfo = await pixivCacheManager?.getFileFromCache(targetUrl);
      if (fileInfo != null && mounted && !_canLoad && !_imageShown) {
        // 异步读取，避免同步 IO 阻塞 UI 线程
        final bytes = await fileInfo.file.readAsBytes();
        // 代际校验：异步读取期间 url 可能已切换，复检后才能填入字节。
        // 图片已显示（_imageShown）时不覆盖，避免"显示中→空白→淡入"闪烁
        if (bytes.isNotEmpty &&
            mounted &&
            url == targetUrl &&
            _cachedBytes == null &&
            !_imageShown) {
          // 缓存命中：直接填入 _cachedBytes，build 走"已缓存"分支
          //（Image.memory 直接显示，完全绕过 CachedNetworkImage 管线）
          _coordinator.cancel(targetUrl);
          setState(() {
            _cachedBytes = Uint8List.fromList(bytes);          });
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
    // 网络重试期间图片未在显示：复位，使重试后缓存回退/直下可用
    _imageShown = false;
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

    // 方案 B: 如果已从缓存加载，直接显示（不受优先级协调影响）
    if (_cachedBytes != null) {
      return Container(
        width: width,
        height: height,
        color: Theme.of(context).cardColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 解码期间先显示占位（缩略图），避免大图重新解码时空白
            if (placeWidget != null) placeWidget!,
            Image.memory(
              _cachedBytes!,
              fit: fit ?? BoxFit.fitWidth,
              width: width,
              height: height,
              // 按显示宽度解码：否则原始大图（如 5000×7000）全尺寸解码，
              // 单帧可达上百 MB，且以全尺寸条目挤占 ImageCache
              cacheWidth: memCacheWidth,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || !fade) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                  child: child,
                );
              },
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
    // 槽位使命在"请求发出"即完成：构建 CachedNetworkImage（触发 resolve/
    // 下载）前释放槽位，让队列推进——大图下载+解码全程占槽会阻塞
    // 第 7+ 张排队（协调器只应限制请求发起并发，而非下载时长）
    _releaseSlot();
    return CachedNetworkImage(
      key: ValueKey('$_retryCount'),
      useOldImageOnUrlChange: true,
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
        // 图片已渲染：此后禁止 _cachedBytes 覆盖（见 _imageShown 注释）
        _imageShown = true;
        return Image(
          image: imageProvider,
          fit: fit ?? BoxFit.fitWidth,
          width: width,
          height: height,
          gaplessPlayback: true,
        );
      },
      errorWidget: (context, url, error) {
        _releaseSlot();
        // 进入错误 UI = 图片已不在显示，_imageShown 失效：复位以恢复
        // 缓存回退能力（否则曾成功显示的 url 重试失败后，本地磁盘缓存
        // 回退被 _imageShown 守卫永久阻断，直到 url 再次变化）
        _imageShown = false;
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
                    _imageShown = false; // 复位显示状态，恢复缓存回退能力
                    setState(() {});
                  },
                  child: Text(":("),
                ),
              ],
            ),
          ),
        );
      },
      // 快速淡入淡出动画：350ms easeOut 曲线，提供丝滑顺眼的过渡体验
      fadeInDuration: widget.fade ? const Duration(milliseconds: 350) : Duration.zero,
      fadeInCurve: Curves.easeOut,
      fadeOutDuration: widget.fade ? const Duration(milliseconds: 350) : Duration.zero,
      imageUrl: url,
      cacheManager: pixivCacheManager,
      height: height,
      width: width,
      fit: fit ?? BoxFit.fitWidth,
      memCacheWidth: memCacheWidth,
      httpHeaders: {...Hoster.header(url: url)},
    );
  }

  @override
  void dispose() {
    _slotTimer?.cancel();
    _coordinator.cancel(widget.url);
    super.dispose();
  }
}

class PixivProvider {
  /// [width] 非空时按宽度限制解码尺寸（ResizeImage 包装，ImageCache key
  /// 含宽度维度）：大图查看器（PhotoZoomPage）传屏宽 × dpr × 2（上限
  /// 4096），避免 5000×7000 原图全尺寸解码 140MB 位图的内存尖峰与
  /// ImageCache 驱逐；不传则按原始尺寸解码
  static ImageProvider url(String url, {String? preUrl, int? width}) {
    final provider = CachedNetworkImageProvider(
      url,
      headers: Hoster.header(url: preUrl),
      cacheManager: pixivCacheManager,
    );
    if (width == null || width <= 0) return provider;
    return ResizeImage(provider, width: width);
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
