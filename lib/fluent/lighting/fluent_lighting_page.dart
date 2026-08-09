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

import 'package:easy_refresh/easy_refresh.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/fluent/component/illust_card.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/utils.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

class WaterFallLoading extends StatefulWidget {
  const WaterFallLoading({Key? key}) : super(key: key);

  @override
  State<WaterFallLoading> createState() => _WaterFallLoadingState();
}

class _WaterFallLoadingState extends State<WaterFallLoading> {
  @override
  Widget build(BuildContext context) {
    return Container(
      child: Center(child: ProgressRing()),
    );
  }
}

class LightingList extends StatefulWidget {
  final LightSource source;
  final Widget? header;
  final bool? isNested;
  final ScrollController? scrollController;
  final String? portal;

  const LightingList(
      {Key? key,
      required this.source,
      this.header,
      this.isNested,
      this.scrollController,
      this.portal})
      : super(key: key);

  @override
  _LightingListState createState() => _LightingListState();
}

class _LightingListState extends State<LightingList> {
  late LightingStore _store;
  late bool _isNested;
  late ScrollController _scrollController;
  // 本列表独立的图片加载协调器：可视范围与队列不与其他页面互相干扰
  late ImageLoadCoordinator _coordinator;

  @override
  void didUpdateWidget(LightingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _store.source = widget.source;
      _fetch();
    }
  }

  _fetch() async {
    await _store.fetch(force: true);
    if (!_isNested && _store.errorMessage == null && !_store.iStores.isEmpty) {
      _scrollController.position.jumpTo(0.0);
    }
  }

  ReactionDisposer? disposer;

  void Function()? _disableListener;

  @override
  void initState() {
    _isNested = widget.isNested ?? false;
    _scrollController = widget.scrollController ?? ScrollController();
    _refreshController = EasyRefreshController(
        controlFinishLoad: true, controlFinishRefresh: true);
    _store = LightingStore(
      widget.source,
    );
    _store.easyRefreshController = _refreshController;

    // 图片加载协调器 + 回顶按钮：监听滚动位置
    if (widget.scrollController == null && !_isNested) {
      _scrollController.addListener(_onScrollUpdate);
    }
    // 本列表独立的图片加载协调器：可视范围与队列不与其他页面互相干扰
    _coordinator = ImageLoadCoordinator.create();
    // 回顶按钮：Timer 轮询（嵌套页面用 PrimaryScrollController）
    _pollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      final ctrl = _isNested
          ? PrimaryScrollController.maybeOf(context)
          : (_scrollController.hasClients ? _scrollController : null);
      if (ctrl == null || !ctrl.hasClients) return;
      final visible = ctrl.position.pixels > 500;
      if (_backToTopNotifier.value != visible) {
        _backToTopNotifier.value = visible;
      }
    });

    super.initState();
    _store.fetch();

    // Load More Detecter
    _disableListener =
        initializeScrollController(_scrollController, _store.fetchNext);
  }

  Timer? _pollTimer;

  final ValueNotifier<bool> _backToTopNotifier = ValueNotifier(false);

  void _onScrollUpdate() {
    if (!_scrollController.hasClients) return;
    final metrics = _scrollController.position;
    final pixels = metrics.pixels;

    // 回顶按钮可见性
    final visible = pixels > 500;
    if (_backToTopNotifier.value != visible) {
      _backToTopNotifier.value = visible;
    }

    // 图片加载协调器可视范围
    const approxItemHeight = 280.0;
    final start = (pixels / approxItemHeight)
        .floor()
        .clamp(0, _store.iStores.length);
    final end =
        ((pixels + metrics.viewportDimension) / approxItemHeight)
            .ceil()
            .clamp(0, _store.iStores.length);
    _coordinator.updateVisibleRange(start, end);
  }

  bool _onScrollNotify(ScrollNotification notification) {
    final visible = notification.metrics.pixels > 500;
    if (_backToTopNotifier.value != visible) {
      _backToTopNotifier.value = visible;
    }
    return false;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    if (_disableListener != null) _disableListener!();
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _backToTopNotifier.dispose();
    _store.dispose();
    _refreshController.dispose();
    _coordinator.dispose(); // 释放独立协调器的定时器与队列
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 列表作用域：子树中的 PixivImage 使用本列表独立的协调器实例
    return ImageCoordinatorScope(
      coordinator: _coordinator,
      child: Stack(
      children: [
        Observer(builder: (_) {
          return _buildContent(context);
        }),
        ValueListenableBuilder<bool>(
          valueListenable: _backToTopNotifier,
          builder: (_, visible, __) {
            if (!visible) return const SizedBox.shrink();
            return Positioned(
              right: 16,
              bottom: 80, // 避开底部导航栏 (extendBody: true)
              child: Container(
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).accentColor,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(FluentIcons.chevron_up, color: Colors.white),
                  onPressed: () {
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(0);
                    }
                  },
                ),
              ),
            );
          },
        ),
      ],
      ),
    );
  }

  late EasyRefreshController _refreshController;

  Widget _buildWithoutHeader(context) {
    _store.iStores.removeWhere((element) => element.illusts!.hateByUser());
    return EasyRefresh.builder(
      controller: _refreshController,
      header: PixezDefault.header(context),
      onRefresh: () {
        _store.fetch(force: true);
      },
      onLoad: () {
        _store.fetchNext();
      },
      childBuilder: (context, physics) =>
          NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotify,
        child: WaterfallFlow.builder(
          physics: physics,
          controller: widget.isNested ?? false ? null : _scrollController,
          padding: EdgeInsets.all(5.0),
          itemCount: _store.iStores.length,
          itemBuilder: (context, index) {
            return _buildItem(index);
          },
          gridDelegate: _buildGridDelegate(),
        ),
      ),
    );
  }

  bool needToBan(Illusts illust) {
    for (var i in muteStore.banillusts) {
      if (i.illustId == illust.id.toString()) return true;
    }
    for (var j in muteStore.banUserIds) {
      if (j.userId == illust.user.id.toString()) return true;
    }
    for (var t in muteStore.banTags) {
      for (var f in illust.tags) {
        if (f.name == t.name) return true;
      }
    }
    return false;
  }

  Widget _buildContent(context) {
    return _store.errorMessage != null
        ? _buildErrorContent(context)
        : _store.iStores.isNotEmpty
            ? (widget.header != null
                ? _buildWithHeader(context)
                : _buildWithoutHeader(context))
            : Container(
                child: _store.refreshing ? WaterFallLoading() : Container(),
              );
  }

  Container _buildErrorContent(context) {
    return Container(
      child: Column(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            height: 50,
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child:
                Text(':(', style: FluentTheme.of(context).typography.subtitle),
          ),
          Button(
              onPressed: () {
                _store.fetch(force: true);
              },
              child: Text(I18n.of(context).retry)),
          Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                (_store.errorMessage?.contains("400") == true
                    ? '${I18n.of(context).error_400_hint}\n ${_store.errorMessage}'
                    : '${_store.errorMessage}'),
              ))
        ],
      ),
    );
  }

  Widget _buildWithHeader(BuildContext context) {
    return EasyRefresh.builder(
      controller: _refreshController,
      header: PixezDefault.header(context),
      onRefresh: () {
        _store.fetch(force: true);
      },
      onLoad: () {
        _store.fetchNext();
      },
      childBuilder: ((context, physics) {
        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotify,
          child: CustomScrollView(
            physics: physics,
            controller:
                widget.isNested ?? false ? null : _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Container(child: widget.header),
              ),
              SliverWaterfallFlow(
                gridDelegate: _buildGridDelegate(),
                delegate: _buildSliverChildBuilderDelegate(context),
              )
            ],
          ),
        );
      }),
    );
  }

  SliverChildBuilderDelegate _buildSliverChildBuilderDelegate(
      BuildContext context) {
    _store.iStores.removeWhere((element) => element.illusts!.hateByUser());
    return SliverChildBuilderDelegate((BuildContext context, int index) {
      return IllustCard(
        index: index,
        store: _store.iStores[index],
        lightingStore: _store,
        iStores: _store.iStores,
      );
    }, childCount: _store.iStores.length);
  }

  SliverWaterfallFlowDelegate _buildGridDelegate() {
    var count = 2;
    if (userSetting.crossAdapt) {
      count = _buildSliderValue();
    } else {
      count = (MediaQuery.of(context).orientation == Orientation.portrait)
          ? userSetting.crossCount
          : userSetting.hCrossCount;
    }
    return SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
      crossAxisCount: count,
    );
  }

  int _buildSliderValue() {
    final currentValue =
        (MediaQuery.of(context).orientation == Orientation.portrait
                ? userSetting.crossAdapterWidth
                : userSetting.hCrossAdapterWidth)
            .toDouble();
    var nowAdaptWidth = max(currentValue, 250.0);
    nowAdaptWidth = min(nowAdaptWidth, 2160.0);
    final screenWidth = MediaQuery.of(context).size.width;
    final result = max(screenWidth / nowAdaptWidth, 1.0).toInt();
    return result;
  }

  Widget _buildItem(int index) {
    return IllustCard(
      index: index,
      store: _store.iStores[index],
      lightingStore: _store,
      iStores: _store.iStores,
    );
  }
}
