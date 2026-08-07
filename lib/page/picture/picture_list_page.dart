import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/picture/illust_store.dart';
import 'package:pixez/utils/swipe_evaluator.dart';

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
  Duration _gestureDuration = Duration.zero;
  Duration _pointerDownTimeStamp = Duration.zero;
  // 手势代际 token：防止迟到的延迟回调误判（快速连续手势）
  int _gestureToken = 0;
  // 瞬时释放速度（最后一段 move 的间隔速度，比全程平均更接近真实甩动）
  double _releaseVelocityDx = 0;
  double? _lastMoveDx;
  Duration? _lastMoveTimeStamp;

  // 滑动判定器
  final SwipeEvaluator _swipeEvaluator = const SwipeEvaluator();

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
    _gestureDuration = Duration.zero;
    _pointerDownTimeStamp = e.timeStamp;
    _releaseVelocityDx = 0;
    _lastMoveDx = null;
    _lastMoveTimeStamp = null;
    _gestureToken++;
    // 新手势开始时，取消正在进行的切换动画
    if (_evaluating) {
      _evaluating = false;
      _pageController.jumpTo(_pageController.page ?? nowPosition.toDouble());
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointerIsDown || _pointerDownPos == null) return;
    final now = e.timeStamp;
    if (_lastMoveTimeStamp != null && _lastMoveDx != null) {
      final dtMs = (now - _lastMoveTimeStamp!).inMilliseconds;
      if (dtMs > 0) {
        _releaseVelocityDx = (e.position.dx - _lastMoveDx!) * 1000 / dtMs;
      }
    }
    _lastMoveDx = e.position.dx;
    _lastMoveTimeStamp = now;
    _totalDx = e.position.dx - _pointerDownPos!.dx;
    _totalDy = e.position.dy - _pointerDownPos!.dy;
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerIsDown = false;
    _gestureDuration = e.timeStamp - _pointerDownTimeStamp;
    final token = ++_gestureToken;
    // 手势已结束（无原生动画竞争，physics 恒为 NeverScrollable），
    // 短延迟让 pointer 事件流处理完毕即可判定
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted && token == _gestureToken) _evaluateSwipe();
    });
  }

  void _onPointerCancel(PointerCancelEvent e) {
    // 系统手势接管（通知栏/来电等）：重置状态并使挂起的判定失效
    _pointerIsDown = false;
    _gestureToken++;
  }

  void _evaluateSwipe() {
    if (_evaluating) return;
    // 空列表保护：clamp(0, -1) 会抛 ArgumentError
    if (_iStores.isEmpty) return;
    // 使用实际手势耗时计算速度（至少 50ms 防止除零）
    final durationMs = _gestureDuration.inMilliseconds.clamp(50, 2000);
    final durationSec = durationMs / 1000.0;
    final avgVelocityDx = _totalDx / durationSec;

    // 使用统一的滑动判定器（释放速度优先，平均速度兜底）
    final result = _swipeEvaluator.evaluate(
      totalDx: _totalDx,
      totalDy: _totalDy,
      velocityDx: _releaseVelocityDx.abs() > 0 ? _releaseVelocityDx : avgVelocityDx,
      velocityDy: _totalDy / durationSec,
      screenWidth: screenWidth * 2,
    );

    if (!result.accepted) return; // 拒绝：不做任何动画（无原生 fling 竞争）

    final target = _totalDx < 0 ? _dragStartPage + 1 : _dragStartPage - 1;
    // 上限为 _iStores.length：最后一页后可滑到"加载更多"页（PictureListNextPage）
    final clamped = target.clamp(0, _iStores.length);
    if (clamped == _dragStartPage) return;

    _evaluating = true;
    _pageController
        .animateToPage(clamped,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut)
        .then((_) {
      _evaluating = false;
      if (mounted) setState(() => nowPosition = clamped);
    });
  }

  @override
  Widget build(BuildContext context) {
    screenWidth = MediaQuery.of(context).size.width / 2;
    return Observer(builder: (_) {
      return Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: PageView.builder(
          controller: _pageController,
          // 恒为 NeverScrollable：翻页完全由自定义判定驱动，
          // 避免原生 snap/fling 动画与 300ms 后判定互相竞争（翻过去又弹回）
          physics: const NeverScrollableScrollPhysics(),
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
