import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
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
  double _dragTotalDx = 0;
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
              child: GestureDetector(
                onHorizontalDragStart: (_) {
                  _dragTotalDx = 0;
                  _dragStartPage = nowPosition;
                  _dragStartOffset =
                      _pageController.page ?? nowPosition.toDouble();
                  _gestureToken++;
                  // 新手势开始时，取消进行中的切换/回弹动画
                  if (_evaluating) {
                    _evaluating = false;
                    _pageController
                        .jumpTo(_pageController.page ?? _dragStartOffset);
                  }
                },
                onHorizontalDragUpdate: (details) {
                  _dragTotalDx += details.delta.dx;
                  // 跟手：jumpTo 以像素为单位，页偏移需换算（页 × 视口宽）
                  _pageController.jumpTo(
                      _dragStartOffset * _pageWidth - _dragTotalDx);
                },
                onHorizontalDragCancel: () {
                  // 手势被系统打断：回弹原页
                  _animateTo(_dragStartPage);
                },
                onHorizontalDragEnd: (details) {
                  // 空列表保护：clamp(0, -1) 会抛 ArgumentError
                  if (_iStores.isEmpty) return;
                  final v = details.velocity.pixelsPerSecond;

                  // 使用统一的滑动判定器（水平手势的垂直分量已被竞技场裁决）
                  final result = _swipeEvaluator.evaluate(
                    totalDx: _dragTotalDx,
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
                  // clamp 到合法范围（上限含"加载更多"页）；拒绝/越界回弹
                  target = target.clamp(0, _iStores.length);
                  _animateTo(target);
                },
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
