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

import 'dart:math';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/component/back_to_top_button.dart';
import 'package:pixez/component/illust_card.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/exts.dart';
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
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class LightingList extends StatefulWidget {
  final LightSource source;
  final Widget? header;
  final bool? isNested;
  final ScrollController? scrollController;
  final String? portal;
  final bool? ai;
  final bool Function(Illusts)? filter;

  const LightingList(
      {Key? key,
      required this.source,
      this.header,
      this.isNested,
      this.scrollController,
      this.portal,
      this.ai,
      this.filter})
      : super(key: key);

  @override
  _LightingListState createState() => _LightingListState();
}

class _LightingListState extends State<LightingList> {
  late LightingStore _store;
  late bool _isNested;
  late ScrollController _scrollController;
  late bool _ai;

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
    if (!_isNested &&
        _store.errorMessage == null &&
        !_store.iStores.isEmpty &&
        _scrollController.hasClients) {
      _scrollController.position.jumpTo(0.0);
    }
  }

  ReactionDisposer? disposer;

  @override
  void initState() {
    _ai = widget.ai ?? false;
    _isNested = widget.isNested ?? false;
    _scrollController = widget.scrollController ?? ScrollController();
    _refreshController = EasyRefreshController(
        controlFinishLoad: true, controlFinishRefresh: true);
    _store = LightingStore(
      widget.source,
    );
    _store.easyRefreshController = _refreshController;

    // 图片加载协调器：监听滚动位置（仅非嵌套模式）
    if (!_isNested) {
      _scrollController.addListener(_onScrollUpdate);
    }

    super.initState();
    _store.fetch();
  }

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
    ImageLoadCoordinator.instance.updateVisibleRange(start, end);
  }

  /// 滚动通知处理：在 EasyRefresh.childBuilder 内部捕获
  /// 嵌套模式和非嵌套模式都通过此方法更新回顶按钮
  bool _onScrollNotify(ScrollNotification notification) {
    final visible = notification.metrics.pixels > 500;
    if (_backToTopNotifier.value != visible) {
      _backToTopNotifier.value = visible;
    }

    // 嵌套模式下也需要更新图片加载协调器
    if (_isNested) {
      const approxItemHeight = 280.0;
      final pixels = notification.metrics.pixels;
      final viewport = notification.metrics.viewportDimension;
      final start = (pixels / approxItemHeight)
          .floor()
          .clamp(0, _store.iStores.length);
      final end = ((pixels + viewport) / approxItemHeight)
          .ceil()
          .clamp(0, _store.iStores.length);
      ImageLoadCoordinator.instance.updateVisibleRange(start, end);
    }

    return false; // 不消费，让 EasyRefresh 也能收到
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _backToTopNotifier.dispose();
    _store.dispose();
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Observer(builder: (_) {
          return _buildContent(context);
        }),
        ValueListenableBackToTopButton(
          notifier: _backToTopNotifier,
          heroTag: 'bt_${_store.hashCode}',
          onPressed: () {
            // 嵌套模式使用 PrimaryScrollController
            final ctrl = _isNested
                ? PrimaryScrollController.maybeOf(context)
                : (_scrollController.hasClients ? _scrollController : null);
            if (ctrl != null && ctrl.hasClients) {
              ctrl.jumpTo(0);
            }
          },
        ),
      ],
    );
  }

  late EasyRefreshController _refreshController;

  Widget _buildWithoutHeader(context) {
    _store.iStores.removeWhere((element) {
      if (element.illusts!.hateByUser(ai: _ai)) return true;
      if (widget.filter != null && !widget.filter!(element.illusts!)) {
        return true;
      }
      return false;
    });
    return EasyRefresh.builder(
      controller: _refreshController,
      header: PixezDefault.header(context),
      footer: PixezDefault.footer(context),
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
          controller:
              widget.isNested ?? false ? null : _scrollController,
          padding: const EdgeInsets.all(5.0),
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

  Widget _buildErrorContent(context) {
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
                Text(':(', style: Theme.of(context).textTheme.headlineMedium),
          ),
          TextButton(
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
      footer:
          PixezDefault.footer(context, position: IndicatorPosition.locator),
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
                    ),
                    const FooterLocator.sliver(),
                  ],
                ),
              );
            }),
        );
  }

  SliverChildBuilderDelegate _buildSliverChildBuilderDelegate(
      BuildContext context) {
    _store.iStores.removeWhere((element) {
      if (element.illusts!.hateByUser(ai: _ai)) return true;
      if (widget.filter != null && !widget.filter!(element.illusts!)) {
        return true;
      }
      return false;
    });
    return SliverChildBuilderDelegate((BuildContext context, int index) {
      return IllustCard(
        index: index,
        lightingStore: _store,
        store: _store.iStores[index],
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
    var nowAdaptWidth = max(currentValue, 50.0);
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
