import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/picture/illust_store.dart';

class PictureListPage extends StatefulWidget {
  final IllustStore store;
  final List<IllustStore> iStores;
  final String? heroString;
  final LightingStore? lightingStore;

  const PictureListPage(
      {Key? key,
      required this.lightingStore,
      required this.store,
      required this.iStores,
      this.heroString})
      : super(key: key);

  @override
  _PictureListPageState createState() => _PictureListPageState();
}

class _PictureListPageState extends State<PictureListPage> {
  late PageController _pageController;
  late int nowPosition;
  late LightingStore? _lightingStore;
  late List<IllustStore> _iStores;
  late IllustStore _store;
  double screenWidth = 0;

  // 方向追踪
  Offset? _pointerDownPos;
  double _totalDx = 0;
  double _totalDy = 0;
  bool _pointerIsDown = false;
  int _dragStartPage = 0;
  bool _evaluating = false;

  @override
  void initState() {
    _store = widget.store;
    _iStores = widget.iStores;
    _lightingStore = widget.lightingStore;
    nowPosition = _iStores.indexOf(_store);
    _pageController = PageController(initialPage: nowPosition);
    super.initState();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointerDownPos = e.position;
    _totalDx = 0;
    _totalDy = 0;
    _pointerIsDown = true;
    _dragStartPage = nowPosition;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointerIsDown || _pointerDownPos == null) return;
    _totalDx = e.position.dx - _pointerDownPos!.dx;
    _totalDy = e.position.dy - _pointerDownPos!.dy;
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerIsDown = false;
    // 等 PageView snap/fling 动画结束后判定
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _evaluateSwipe();
    });
  }

  void _evaluateSwipe() {
    if (_evaluating) return;
    final currentPage = _pageController.page?.round() ?? nowPosition;
    if (currentPage == _dragStartPage) return;

    // 判定 1：方向需偏向水平
    if (_totalDx.abs() <= _totalDy.abs() * 1.5) {
      _bounceBack();
      return;
    }
    // 判定 2：水平位移需超过屏幕宽度 50%
    if (_totalDx.abs() < screenWidth) {
      _bounceBack();
      return;
    }
    // 接受
    setState(() => nowPosition = currentPage);
  }

  void _bounceBack() {
    _evaluating = true;
    _pageController.animateToPage(_dragStartPage,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut)
      .then((_) => _evaluating = false);
  }

  @override
  Widget build(BuildContext context) {
    screenWidth = MediaQuery.of(context).size.width / 2;
    return Observer(builder: (_) {
      return Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: PageView.builder(
          controller: _pageController,
          physics: userSetting.swipeChangeArtwork
              ? null
              : const NeverScrollableScrollPhysics(),
          itemBuilder: (BuildContext context, int index) {
            if (index == _iStores.length && _lightingStore != null) {
              return PictureListNextPage(
                lightingStore: _lightingStore!,
              );
            }
            final f = _iStores[index];
            String? tag = nowPosition == index ? widget.heroString : null;
            return IllustLightingPage(
              id: f.id,
              heroString: tag,
              store: f,
            );
          },
          itemCount: _iStores.length + 1,
        ),
      );
    });
  }
}

class PictureListNextPage extends StatefulWidget {
  final LightingStore lightingStore;
  const PictureListNextPage({super.key, required this.lightingStore});

  @override
  State<PictureListNextPage> createState() => _PictureListNextPageState();
}

class _PictureListNextPageState extends State<PictureListNextPage> {
  late LightingStore _lightingStore;
  bool? loadResult;

  @override
  void initState() {
    _lightingStore = widget.lightingStore;
    super.initState();
    _maybeFetch(true);
  }

  _maybeFetch(bool firstIn) async {
    if (_lightingStore.nextUrl == null) return;
    try {
      if (!firstIn) setState(() => loadResult = null);
      final result = await _lightingStore.fetchNext();
      if (mounted) setState(() => loadResult = result);
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_lightingStore.nextUrl == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text("No More")),
      );
    }
    if (loadResult == false) {
      return Scaffold(
        appBar: AppBar(),
        body: Container(
            child: Center(
          child: Column(children: [
            Text("Load Failed"),
            TextButton(
                onPressed: () => _maybeFetch(false), child: Text("Retry"))
          ]),
        )),
      );
    }
    return Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
