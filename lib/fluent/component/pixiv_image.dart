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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_cache_manager_dio/flutter_cache_manager_dio.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/image_load_coordinator.dart';
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
DioCacheManager? pixivCacheManager = DioCacheManager.instance;

class PixivImage extends StatefulWidget {
  final String url;
  final Widget? placeWidget;
  final bool fade;
  final BoxFit? fit;
  final bool? enableMemoryCache;
  final double? height;
  final double? width;
  final String? host;
  final String? errorHint;
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
    this.errorHint,
    this.priorityIndex,
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
    final dio = Dio();
    dio.interceptors.add(
      PixivImageSourceInterceptor(
        networkMode: () => userSetting.networkMode,
        pictureSource: () => userSetting.pictureSource,
      ),
    );
    dio.interceptors.add(LogInterceptor(responseBody: false));
    dio.httpClientAdapter = ConversionLayerAdapter(client);
    _cacheDio = dio;
    DioCacheManager.initialize(dio);
    _warmUpWorker(dio);
  }

  static void _warmUpWorker(Dio dio) {
    if (userSetting.pictureSource == ImageHost) return;
    final source = userSetting.pictureSource;
    if (source == null || source.isEmpty) return;
    final warmUrl = source.startsWith('http') ? source : 'https://$source';
    dio.head(warmUrl).then((_) {}).catchError((_) {});
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

  // 优先级协调状态
  bool _canLoad = true;
  bool _slotReleased = false;
  String? _registeredUrl;

  ImageLoadCoordinator get _coordinator => ImageLoadCoordinator.instance;

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

    // 如果参与了优先级协调，立即注册槽位（同步，无帧延迟）
    if (widget.priorityIndex != null) {
      _canLoad = false;
      _registeredUrl = widget.url;
      _requestSlot();
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
      _slotReleased = false;
      setState(() {
        url = widget.url;
        width = widget.width;
        height = widget.height;
      });
      // 重新请求槽位
      if (widget.priorityIndex != null) {
        _canLoad = false;
        _registeredUrl = widget.url;
        _requestSlot();
      }
    }
  }

  /// 向协调器请求加载槽位（同步，无延迟）。
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
      if (mounted) setState(() => _canLoad = true);
    }

    // 后台检查缓存：如果在排队中且缓存命中，绕过协调器立即显示
    _tryCacheBypass(targetUrl);
  }

  /// 后台检查文件缓存，命中则立即显示并释放排队槽位
  Future<void> _tryCacheBypass(String targetUrl) async {
    if (_canLoad) return;
    try {
      final resolvedUrl = PixivImageSource.resolve(
        targetUrl,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      final fileInfo = await pixivCacheManager?.getFileFromCache(resolvedUrl);
      if (fileInfo != null && mounted && !_canLoad) {
        final bytes = fileInfo.file.readAsBytesSync();
        if (bytes.isNotEmpty) {
          _coordinator.cancel(targetUrl);
          setState(() => _canLoad = true);
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
    setState(() => _canLoad = true);
  }

  /// 释放槽位
  void _releaseSlot() {
    if (_slotReleased) return;
    _slotReleased = true;
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

    // 优先级协调：尚未获得槽位时显示占位符
    if (!_canLoad) {
      return widget.placeWidget ?? Container(height: height);
    }

    return CachedNetworkImage(
      key: ValueKey('$_retryCount'),
      placeholder: (context, url) =>
          widget.placeWidget ?? Container(height: height),
      imageBuilder: (context, imageProvider) {
        _releaseSlot();
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
                HyperlinkButton(
                  onPressed: () {
                    _retryCount = 0;
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
      httpHeaders: Hoster.header(url: url),
    );
  }

  @override
  void dispose() {
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
