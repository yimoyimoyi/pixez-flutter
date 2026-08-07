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

  // 滑动状态（自定义跟手 + 判定）
  double _totalDx = 0;
  int _dragStartPage = 0;
  double _dragStartOffset = 0;
  bool _evaluating = false;
  // 手势代际 token：防止旧手势的动画回调误判（快速连续手势）
  int _gestureToken = 0;
  double _pageWidth = 1;

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

  void _onDragStart(DragStartDetails d) {
    _totalDx = 0;
    _dragStartPage = nowPosition;
    _dragStartOffset = _pageController.page ?? nowPosition.toDouble();
    _gestureToken++;
    // 新手势开始时，取消进行中的切换/回弹动画
    if (_evaluating) {
      _evaluating = false;
      _pageController.jumpTo(_pageController.page ?? _dragStartOffset);
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _totalDx += d.delta.dx;
    // 跟手：图片随手指 1:1 平移。
    // 注意：jumpTo 的单位是像素（ScrollController 语义），
    // 而 _dragStartOffset 是页单位，需换算：像素 = 页 × 视口宽
    _pageController.jumpTo(_dragStartOffset * _pageWidth - _totalDx);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_iStores.isEmpty) return;
    final v = d.velocity.pixelsPerSecond;
    // 水平手势的垂直分量已被手势竞技场裁决为不主导，dy 传 0
    final result = _swipeEvaluator.evaluate(
      totalDx: _totalDx,
      totalDy: 0,
      velocityDx: v.dx,
      velocityDy: v.dy,
      screenWidth: _pageWidth,
    );

    int target = _dragStartPage;
    if (result.accepted) {
      target = result.direction == SwipeDirection.left
          ? _dragStartPage + 1
          : _dragStartPage - 1;
    }
    // clamp 到合法范围（上限含"加载更多"页）；拒绝/越界回弹当前页
    target = target.clamp(0, _iStores.length);
    _animateTo(target);
  }

  void _onDragCancel() {
    // 系统手势接管（通知栏/来电等）：回弹原页
    _animateTo(_dragStartPage);
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
  Widget build(BuildContext context) {
    _pageWidth = MediaQuery.of(context).size.width;
    return Observer(builder: (_) {
      // 自定义跟手滑动：拖动时图片随手指平移（jumpTo），
      // 松手后判定（速度优先/位移兜底）→ 平滑切换或回弹。
      // 手势竞技场自动裁决水平 vs 内层纵向滚动，斜向拖拽不会误触发
      return GestureDetector(
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragCancel,
        child: PageView.builder(
          controller: _pageController,
          // 恒为 NeverScrollable：跟手与判定完全由本组件驱动
          physics: const NeverScrollableScrollPhysics(),
          // 预构建并保留相邻页：慢速滑动到页面边界时页面反复进出视口
          // 销毁重建，导致图片异步加载闪烁抖动
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
