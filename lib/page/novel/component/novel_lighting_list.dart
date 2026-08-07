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
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/component/back_to_top_button.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/lighting/lighting_store.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/page/novel/component/novel_lighting_store.dart';
import 'package:pixez/page/novel/viewer/novel_viewer.dart';
import 'package:pixez/exts.dart';

class NovelLightingList extends StatefulWidget {
  final FutureGet futureGet;
  final bool? isNested;

  const NovelLightingList({Key? key, required this.futureGet, this.isNested})
      : super(key: key);

  @override
  _NovelLightingListState createState() => _NovelLightingListState();
}

class _NovelLightingListState extends State<NovelLightingList> {
  late EasyRefreshController _easyRefreshController;
  late NovelLightingStore _store;
  late bool _isNested;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _backToTopNotifier = ValueNotifier(false);

  Timer? _pollTimer;

  @override
  void initState() {
    _isNested = widget.isNested ?? false;
    _easyRefreshController = EasyRefreshController(
        controlFinishLoad: true, controlFinishRefresh: true);
    _store = NovelLightingStore(widget.futureGet, _easyRefreshController);
    _scrollController.addListener(_onScrollUpdate);
    // 回顶按钮：Timer 轮询
    _pollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted || !_scrollController.hasClients) return;
      final visible = _scrollController.position.pixels > 500;
      if (_backToTopNotifier.value != visible) {
        _backToTopNotifier.value = visible;
      }
    });
    super.initState();
    if (_isNested) _store.fetch();
  }

  void _onScrollUpdate() {
    if (!_scrollController.hasClients) return;
    final visible = _scrollController.position.pixels > 500;
    if (_backToTopNotifier.value != visible) {
      _backToTopNotifier.value = visible;
    }
  }

  @override
  void didUpdateWidget(NovelLightingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.futureGet != widget.futureGet) {
      _store.source = widget.futureGet;
      _store.fetch();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _easyRefreshController.dispose();
    _scrollController.dispose();
    _backToTopNotifier.dispose();
    super.dispose();
  }

  Widget _buildBody(BuildContext context) {
    if (_store.errorMessage != null) {
      return Container(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child:
                  Text(':(', style: Theme.of(context).textTheme.headlineMedium),
            ),
            TextButton(
                onPressed: () {
                  _store.fetch();
                },
                child: Text(I18n.of(context).retry)),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('${_store.errorMessage}'),
            )
          ],
        ),
      );
    }
    return _buildListBody();
  }

  ListView _buildListBody() {
    _store.novels.removeWhere((element) => element.novel?.hateByUser() == true);
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(0),
      itemBuilder: (context, index) {
        Novel novel = _store.novels[index].novel!;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: InkWell(
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                  builder: (BuildContext context) => NovelViewerPage(
                        id: novel.id,
                        novelStore: _store.novels[index],
                      )));
            },
            child: Card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    flex: 5,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Container(
                            width: 80,
                            height: 112,
                            color: Colors.grey.shade200,
                            child: PixivImage(
                              novel.imageUrls.qualityUrl,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 8.0, left: 8.0),
                                child: Text(
                                  novel.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                  maxLines: 3,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      novel.user.name,
                                      maxLines: 1,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall!
                                          .copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .secondary),
                                    ),
                                    Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.article,
                                            size: 12,
                                            color: Theme.of(context)
                                                .textTheme
                                                .labelSmall!
                                                .color,
                                          ),
                                          SizedBox(
                                            width: 2,
                                          ),
                                          Text(
                                            '${novel.textLength}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          )
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8.0),
                                child: Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 2,
                                  runSpacing: 0,
                                  children: [
                                    for (var f in novel.tags)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 1),
                                        child: Text(
                                          f.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      )
                                  ],
                                ),
                              ),
                              Container(
                                height: 8.0,
                              )
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: Column(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        NovelBookmarkButton(novel: novel),
                        Text('${novel.totalBookmarks}',
                            style: Theme.of(context).textTheme.bodySmall)
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
        );
      },
      itemCount: _store.novels.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        EasyRefresh(
          onLoad: () => _store.next(),
          onRefresh: () => _store.fetch(),
          refreshOnStart: _isNested ? false : true,
          controller: _easyRefreshController,
          header: PixezDefault.header(context),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // 注意：返回 true 会终止冒泡，外层 EasyRefresh 将收不到
              // 滚动事件导致下拉刷新/上拉加载失效，故恒返回 false
              final visible = notification.metrics.pixels > 500;
              if (_backToTopNotifier.value != visible) {
                _backToTopNotifier.value = visible;
              }
              return false;
            },
            child: Observer(builder: (context) {
              return _buildBody(context);
            }),
          ),
        ),
        ValueListenableBackToTopButton(
          notifier: _backToTopNotifier,
          // 实例唯一 heroTag：rank 页 TabBarView 中多个实例共存，固定 tag 会崩溃
          heroTag: 'novelBackToTop_${widget.futureGet.hashCode}',
          onPressed: () {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(0);
            }
          },
        ),
      ],
    );
  }
}
