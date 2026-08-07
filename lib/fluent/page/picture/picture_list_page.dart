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
  double screenWidth = 0;

  // 累积拖拽位移
  double _dragTotalDx = 0;
  double _dragTotalDy = 0;

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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        screenWidth = constraints.maxWidth / 2;
        return Stack(
          children: [
            Observer(builder: (_) {
              return PageView.builder(
                controller: _pageController,
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
              );
            }),
            Container(
              margin: const EdgeInsets.all(24),
              child: GestureDetector(
                onHorizontalDragStart: (_) {
                  _dragTotalDx = 0;
                  _dragTotalDy = 0;
                },
                onHorizontalDragUpdate: (details) {
                  _dragTotalDx += details.delta.dx;
                  _dragTotalDy += details.delta.dy;
                },
                onHorizontalDragCancel: () {
                  // 手势被纵向滚动打断等场景：重置累计位移
                  _dragTotalDx = 0;
                  _dragTotalDy = 0;
                },
                onHorizontalDragEnd: (details) {
                  // 空列表保护：clamp(0, -1) 会抛 ArgumentError
                  if (_iStores.isEmpty) return;
                  final v = details.velocity.pixelsPerSecond;

                  // 使用统一的滑动判定器
                  final result = _swipeEvaluator.evaluate(
                    totalDx: _dragTotalDx,
                    totalDy: _dragTotalDy,
                    velocityDx: v.dx,
                    velocityDy: v.dy,
                    screenWidth: screenWidth * 2,
                  );

                  if (!result.accepted) return;

                  int targetPage = nowPosition;
                  if (result.direction == SwipeDirection.left) {
                    targetPage++;
                  } else if (result.direction == SwipeDirection.right) {
                    targetPage--;
                  }
                  targetPage = targetPage.clamp(0, _iStores.length - 1);

                  if (targetPage != nowPosition) {
                    _pageController.animateToPage(targetPage,
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeInOut);
                    setState(() => nowPosition = targetPage);
                  }
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
