import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/fluent/page/picture/illust_lighting_page.dart';
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

  // 滑动状态（自定义跟手 + 判定）
  Offset? _pointerDownPos;
  bool _dragActive = false; // 横向跟手是否激活（方向判定后）
  double _dragTotalDx = 0;
  int _dragStartPage = 0;
  double _dragStartOffset = 0;
  bool _evaluating = false;
  // 手势代际 token：防止旧手势的动画回调误判（快速连续手势）
  int _gestureToken = 0;
  double _pageWidth = 1;
  // 瞬时释放速度（最后一段 move 的间隔速度）
  double _releaseVelocityDx = 0;
  double? _lastMoveDx;
  Duration? _lastMoveTs;

  // 滑动判定器
  final SwipeEvaluator _swipeEvaluator = const SwipeEvaluator();

  @override
  void initState() {
    // 图片查看页打开期间冻结列表协调器队列，避免争抢连接
    ImageLoadCoordinator.enterDetailMode();
    _store = widget.store;
    _iStores = widget.iStores;
    _lightingStore = widget.lightingStore;
    nowPosition = _iStores.indexOf(_store);
    _pageController = PageController(initialPage: nowPosition);
    super.initState();
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointerDownPos = e.position;
    _dragActive = false;
    _dragTotalDx = 0;
    _releaseVelocityDx = 0;
    _lastMoveDx = null;
    _lastMoveTs = null;
    _dragStartPage = nowPosition;
    _dragStartOffset = _pageController.page ?? nowPosition.toDouble();
    _gestureToken++;
    // 新手势开始时，取消进行中的切换/回弹动画
    if (_evaluating) {
      _evaluating = false;
      _pageController.jumpTo(_pageController.page ?? _dragStartOffset);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pointerDownPos == null) return;
    final dx = e.position.dx - _pointerDownPos!.dx;
    final dy = e.position.dy - _pointerDownPos!.dy;

    if (!_dragActive) {
      // 方向判定：纵向主导（多图页面上下滚动）交给内层滚动，
      // 不激活横向跟手；只有横向主导且超过阈值才跟手
      if (dy.abs() > dx.abs()) return;
      if (dx.abs() < 36) return; // 横向激活阈值（≈ 2× touch slop）
      _dragActive = true;
    }

    if (_dragActive) {
      _dragTotalDx = dx;
      // 瞬时速度（释放时用）
      if (_lastMoveTs != null && _lastMoveDx != null) {
        final dtMs = (e.timeStamp - _lastMoveTs!).inMilliseconds;
        if (dtMs > 0) {
          _releaseVelocityDx = (e.position.dx - _lastMoveDx!) * 1000 / dtMs;
        }
      }
      _lastMoveDx = e.position.dx;
      _lastMoveTs = e.timeStamp;
      // 跟手：jumpTo 单位是像素（ScrollController 语义），
      // _dragStartOffset 是页单位，需换算：像素 = 页 × 视口宽
      _pageController.jumpTo(_dragStartOffset * _pageWidth - dx);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final wasActive = _dragActive;
    _pointerDownPos = null;
    _dragActive = false;
    if (!wasActive || _iStores.isEmpty) return;

    // 用瞬时速度判定（无瞬时值则用平均速度兜底）
    final lastTs = _lastMoveTs ?? e.timeStamp;
    final durationMs = (e.timeStamp - lastTs).inMilliseconds;
    final avgV = durationMs > 0 ? _dragTotalDx * 1000 / durationMs : 0.0;
    final v = _releaseVelocityDx.abs() > 0 ? _releaseVelocityDx : avgV;
    final result = _swipeEvaluator.evaluate(
      totalDx: _dragTotalDx,
      totalDy: 0,
      velocityDx: v,
      velocityDy: 0,
      screenWidth: _pageWidth,
    );

    int target = _dragStartPage;
    if (result.accepted) {
      target = result.direction == SwipeDirection.left
          ? _dragStartPage + 1
          : _dragStartPage - 1;
    }
    // clamp 到合法范围（上限含"加载更多"页）；拒绝/越界回弹
    target = target.clamp(0, _iStores.length);
    _animateTo(target);
  }

  void _onPointerCancel(PointerCancelEvent e) {
    // 系统手势接管（通知栏/来电等）：回弹原页
    _pointerDownPos = null;
    if (_dragActive) {
      _dragActive = false;
      _animateTo(_dragStartPage);
    }
  }

  /// 平滑切换到目标页（接受→前进/后退，拒绝→回弹）
  void _animateTo(int target) {
    if (_evaluating) return;
    final token = _gestureToken;
    _evaluating = true;
    _pageController
        .animateToPage(target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic)
        .then((_) {
      _evaluating = false;
      // 旧手势的动画回调不更新状态（新手势已开始）
      if (mounted && token == _gestureToken) {
        setState(() => nowPosition = target);
      }
    });
  }

  @override
  void dispose() {
    ImageLoadCoordinator.exitDetailMode();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _pageWidth = constraints.maxWidth;
        return Stack(
          children: [
            Observer(builder: (_) {
              return PageView.builder(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                // 预构建并保留相邻页：避免滑动到页面边界时页面反复
                // 销毁重建导致图片加载闪烁抖动
                allowImplicitScrolling: true,
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
              );
            }),
            Container(
              margin: const EdgeInsets.all(24),
              // Listener 观察式方向判定（不参与手势竞技场，内层纵向滚动
              // 永远正常）——横向主导才激活跟手，避免多图页面上下滑动误判
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        );
      },
    );
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
      return ScaffoldPage(
        header: const PageHeader(),
        content: const Center(child: Text("No More")),
      );
    }
    if (loadResult == false) {
      return ScaffoldPage(
        header: const PageHeader(),
        content: Center(
          child: Column(children: [
            const Text("Load Failed"),
            HyperlinkButton(
                onPressed: () => _maybeFetch(false),
                child: const Text("Retry")),
          ]),
        ),
      );
    }
    return const ScaffoldPage(
      content: Center(child: ProgressRing()),
    );
  }
}
