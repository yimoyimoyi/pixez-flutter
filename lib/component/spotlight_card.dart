import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/models/spotlight_response.dart';
import 'package:pixez/page/soup/soup_page.dart';

class SpotlightCard extends StatefulWidget {
  final SpotlightArticle spotlight;
  static const platform = MethodChannel('samples.flutter.dev/battery');

  const SpotlightCard({Key? key, required this.spotlight}) : super(key: key);

  @override
  State<SpotlightCard> createState() => _SpotlightCardState();
}

class _SpotlightCardState extends State<SpotlightCard> {
  Offset? _downPos;
  Timer? _longPressTimer;
  bool _isTap = true;

  void _onPointerDown(PointerDownEvent e) {
    _downPos = e.position;
    _isTap = true;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 500), () {
      if (_isTap) {
        _longPressTimer = null;
        Feedback.forLongPress(context);
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => _CoverPreviewPage(
              url: widget.spotlight.thumbnail,
              title: widget.spotlight.title,
            ),
          ),
        );
      }
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_downPos != null && _isTap) {
      final dist = (e.position - _downPos!).distance;
      if (dist > 30) {
        _isTap = false;
        _longPressTimer?.cancel();
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _downPos = null;

    if (!_isTap) return;
    // 短按 → 特辑详情
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (BuildContext context) {
          return SoupPage(
            url: widget.spotlight.articleUrl,
            spotlight: widget.spotlight,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: Container(
          height: 230,
          child: Stack(
            children: <Widget>[
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 160.0,
                  height: 90.0,
                  decoration: BoxDecoration(
                    color: Theme.of(context).splashColor,
                    borderRadius: const BorderRadius.all(Radius.circular(8.0)),
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.bottomCenter,
                    child: ListTile(
                      title: Text(
                        widget.spotlight.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        widget.spotlight.pureTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Card(
                  elevation: 8.0,
                  shape: RoundedRectangleBorder(
                    borderRadius: const BorderRadius.all(Radius.circular(16.0)),
                  ),
                  child: Container(
                    child: CachedNetworkImage(
                      imageUrl: widget.spotlight.thumbnail,
                      fadeInDuration: const Duration(milliseconds: 350),
                      fadeInCurve: Curves.easeOut,
                      fadeOutDuration: const Duration(milliseconds: 350),
                      placeholder: (context, url) =>
                          Container(color: Theme.of(context).cardColor),
                      httpHeaders: Hoster.header(
                        url: widget.spotlight.thumbnail,
                      ),
                      fit: BoxFit.cover,
                      height: 150.0,
                      cacheManager: pixivCacheManager,
                      width: 150.0,
                    ),
                    height: 150.0,
                    width: 150.0,
                  ),
                  clipBehavior: Clip.antiAlias,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头图全屏预览（长按特辑卡片进入）
class _CoverPreviewPage extends StatelessWidget {
  final String url;
  final String title;
  const _CoverPreviewPage({required this.url, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(title, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: InteractiveViewer(
          child: CachedNetworkImage(
            imageUrl: url,
            fadeInDuration: const Duration(milliseconds: 350),
            fadeInCurve: Curves.easeOut,
            fadeOutDuration: const Duration(milliseconds: 350),
            placeholder: (context, url) => const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
            ),
            httpHeaders: Hoster.header(url: url),
            cacheManager: pixivCacheManager,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
