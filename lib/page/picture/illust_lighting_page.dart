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

import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/component/ban_page.dart';
import 'package:pixez/component/common_back_area.dart';
import 'package:pixez/component/null_hero.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/component/star_icon.dart';
import 'package:pixez/er/illust_cacher.dart';
import 'package:pixez/er/image_load_coordinator.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/ban_illust_id.dart';
import 'package:pixez/models/ban_tag.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/page/picture/illust_about_store.dart';
import 'package:pixez/page/picture/illust_detail_content.dart';
import 'package:pixez/page/picture/illust_row_page.dart';
import 'package:pixez/page/picture/illust_store.dart';
import 'package:pixez/page/picture/picture_list_page.dart';
import 'package:pixez/page/picture/tag_for_illust_page.dart';
import 'package:pixez/page/picture/ugoira_loader.dart';
import 'package:pixez/page/picture/user_follow_button.dart';
import 'package:pixez/utils/haptic_util.dart';
import 'package:pixez/page/report/report_items_page.dart';
import 'package:pixez/page/search/result_page.dart';
import 'package:pixez/page/user/user_store.dart';
import 'package:pixez/page/user/users_page.dart';
import 'package:pixez/page/zoom/photo_zoom_page.dart';
import 'package:pixez/supportor_plugin.dart';
import 'package:share_plus/share_plus.dart';

class IllustLightingPage extends StatefulWidget {
  final int id;
  final String? heroString;
  final IllustStore? store;
  final GestureDragEndCallback? onHorizontalDragEnd;

  /// 图片查看器（PictureListPage）内的页：浏览历史由查看器在用户
  /// 实际浏览到（翻页完成）时统一写入，避免 PageView 预构建的
  /// 相邻页（用户未滑到）误入历史
  final bool deferHistory;

  const IllustLightingPage({
    Key? key,
    required this.id,
    this.heroString,
    this.store,
    this.onHorizontalDragEnd,
    this.deferHistory = false,
  }) : super(key: key);

  @override
  State<IllustLightingPage> createState() => _IllustLightingPageState();
}

class _IllustLightingPageState extends State<IllustLightingPage> {
  @override
  Widget build(BuildContext context) {
    switch (userSetting.padMode) {
      case 0:
        MediaQueryData mediaQuery = MediaQuery.of(context);
        final ori = mediaQuery.size.width > mediaQuery.size.height;
        if (ori)
          return _buildRow();
        else
          return _buildVertical();
      case 1:
        return _buildVertical();
      case 2:
        return _buildRow();
      default:
        return Container();
    }
  }

  _buildVertical() {
    return IllustVerticalPage(
      id: widget.id,
      store: widget.store,
      heroString: widget.heroString,
      onHorizontalDragEnd: widget.onHorizontalDragEnd,
      deferHistory: widget.deferHistory,
    );
  }

  _buildRow() {
    return IllustRowPage(
      id: widget.id,
      store: widget.store,
      heroString: widget.heroString,
      onHorizontalDragEnd: widget.onHorizontalDragEnd,
    );
  }
}

class IllustVerticalPage extends StatefulWidget {
  final int id;
  final String? heroString;
  final IllustStore? store;
  final GestureDragEndCallback? onHorizontalDragEnd;

  /// 图片查看器内的页：浏览历史由查看器在翻页完成时统一记录
  final bool deferHistory;

  const IllustVerticalPage({
    Key? key,
    required this.id,
    this.heroString,
    this.store,
    this.onHorizontalDragEnd,
    this.deferHistory = false,
  }) : super(key: key);

  @override
  _IllustVerticalPageState createState() => _IllustVerticalPageState();
}

class _IllustVerticalPageState extends State<IllustVerticalPage>
    with AutomaticKeepAliveClientMixin {
  UserStore? userStore;
  late IllustStore _illustStore;
  late IllustAboutStore _aboutStore;
  late ScrollController _scrollController;
  late EasyRefreshController _refreshController;
  bool tempView = false;
  final _detailKey = GlobalKey<ScaffoldState>();
  // 详情页专用协调器：忽略全局暂停（详情大图在暂停期间仍须加载），
  // 并限制详情页自身大图的并发
  late final ImageLoadCoordinator _detailCoordinator;

  @override
  void initState() {
    _focusNode = FocusNode();
    _refreshController = EasyRefreshController(
      controlFinishLoad: true,
      controlFinishRefresh: true,
    );
    _scrollController = ScrollController();
    _detailCoordinator = ImageLoadCoordinator.create(ignoreGlobalPause: true);
    _illustStore = widget.store ?? IllustStore(widget.id, null);
    _illustStore.fetch(recordHistory: !widget.deferHistory);
    _aboutStore = IllustAboutStore(widget.id, _refreshController);
    super.initState();
    supportTranslateCheck();
  }

  @override
  void didUpdateWidget(covariant IllustVerticalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _illustStore = widget.store ?? IllustStore(widget.id, null);
      _illustStore.fetch(recordHistory: !widget.deferHistory);
      _aboutStore = IllustAboutStore(widget.id, _refreshController);
      LPrinter.d("state change");
    }
  }

  void _loadAbout() {
    if (mounted &&
        _scrollController.hasClients &&
        _aboutStore.illusts.isEmpty &&
        !_aboutStore.fetching) {
      _aboutStore.next();
    }
  }

  Future<void> _autoBookmarkAfterSave(Illusts illust) async {
    if (!userSetting.starAfterSave) {
      return;
    }
    final targetStore = illust.id == _illustStore.id
        ? _illustStore
        : IllustStore(illust.id, illust);
    if (targetStore.state == 0) {
      await targetStore.star(
        restrict: userSetting.defaultPrivateLike ? "private" : "public",
      );
      try {
        final targetIllust = _aboutStore.illusts.firstWhere(
          (e) => e.id == illust.id,
        );
        targetIllust.isBookmarked = true;
        if (mounted) {
          setState(() {});
        }
      } catch (e) {}
    }
  }

  @override
  void dispose() {
    _detailCoordinator.dispose();
    _illustStore.dispose();
    _scrollController.dispose();
    _refreshController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Widget _buildAppbar() {
    return Column(
      children: [
        Container(height: MediaQuery.of(context).padding.top),
        Container(
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                CommonBackArea(),
                IconButton(
                  icon: Icon(Icons.home_outlined, size: 22),
                  onPressed: () => Navigator.of(context)
                      .popUntil((route) => route.isFirst),
                  tooltip: '主页',
                ),
              ]),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.expand_less),
                    onPressed: () async {
                      final context = _detailKey.currentContext;
                      if (context != null) {
                        await Scrollable.ensureVisible(
                          context,
                          duration: Duration(milliseconds: 0),
                          curve: Curves.easeInOut,
                          alignment: 0.5,
                        );
                      }
                    },
                  ),
                  Builder(
                    builder: (buttonContext) {
                      return IconButton(
                        icon: Icon(Icons.more_vert),
                        onPressed: () {
                          HapticUtil.selectionClick();
                          buildShowModalBottomSheet(
                            buttonContext,
                            _illustStore.illusts!,
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  late FocusNode _focusNode;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 详情页打开期间冻结列表协调器队列（封装组件自动配对 enter/exit）
    // 详情页打开期间冻结列表协调器队列 + 详情页专用协调器
    //（忽略全局暂停——否则 priorityIndex 注册会被暂停门控拦截导致
    // 详情大图永不加载；并限制详情大图并发）
    return DetailModeScope(
      child: ImageCoordinatorScope(
        coordinator: _detailCoordinator,
        child: _buildBody(context),
      ),
    );
  }

  /// 详情大图按显示宽度解码：medium 图保持原始解码以复用列表页
  /// ImageCache；大图按屏宽 × dpr 限制解码尺寸（上限 2048），
  /// 否则 50P 级多图漫画全尺寸解码可达 GB 级位图内存（OOM 风险）
  int? _displayCacheWidth(BuildContext context, String url, String mediumUrl) {
    if (url == mediumUrl) return null;
    return (MediaQuery.of(context).size.width *
            MediaQuery.of(context).devicePixelRatio)
        .round()
        .clamp(1, 2048)
        .toInt();
  }

  Widget _buildBody(BuildContext context) {
    return Container(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
        },
        child: Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          floatingActionButton: GestureDetector(
            onLongPress: () {
              _showBookMarkTag();
            },
            onHorizontalDragEnd: (DragEndDetails detail) {
              if (widget.onHorizontalDragEnd != null) {
                widget.onHorizontalDragEnd!(detail);
              }
            },
            child: Observer(
              builder: (context) {
                return Visibility(
                  visible: _illustStore.errorMessage == null,
                  child: FloatingActionButton(
                    heroTag: widget.id,
                    onPressed: () async {
                      if (userSetting.saveAfterStar &&
                          (_illustStore.state == 0)) {
                        saveStore.saveImage(_illustStore.illusts!);
                      }
                      // TODO: 添加配置项 开关和过滤器
                      final List<String>? tags;
                      if (userSetting.autoTagWhenStar) {
                        final filters = [RegExp(r"\d+users入り")];
                        tags = _illustStore.illusts!.tags
                            .map((tag) => tag.name)
                            .where(
                              (tag) =>
                                  !filters.any((regex) => regex.hasMatch(tag)),
                            )
                            .toList();
                      } else {
                        tags = null;
                      }
                      bool success = await _illustStore.star(
                        restrict: userSetting.defaultPrivateLike
                            ? "private"
                            : "public",
                        tags: tags,
                      );
                      if (success && userSetting.followAfterStar) {
                        bool followSuccess = await _illustStore.followAfterStar();
                        if (followSuccess) {
                          userStore?.isFollow = true;
                          BotToast.showText(
                            text:
                                "${_illustStore.illusts!.user.name} ${I18n.of(context).followed}",
                          );
                        }
                      }
                    },
                    child: Observer(
                      builder: (_) {
                        return StarIcon(state: _illustStore.state);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          body: Observer(
            builder: (_) {
              final banWidget = banLogic(context);
              if (banWidget != null) {
                return banWidget;
              }
              return Container(
                child: Stack(
                  children: [
                    _buildContent(context, _illustStore.illusts),
                    _buildAppbar(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget? banLogic(BuildContext context) {
    if (tempView) return null;
    for (var i in muteStore.banillusts) {
      if (i.illustId == widget.id.toString()) {
        return BanPage(
          name: "${I18n.of(context).illust}\n${i.name}\n",
          onPressed: () {
            setState(() {
              tempView = true;
            });
          },
        );
      }
    }
    if (_illustStore.illusts != null) {
      for (var j in muteStore.banUserIds) {
        if (j.userId == _illustStore.illusts!.user.id.toString()) {
          return BanPage(
            name: "${I18n.of(context).painter}\n${j.name}\n",
            onPressed: () {
              setState(() {
                tempView = true;
              });
            },
          );
        }
      }
      for (var t in muteStore.banTags) {
        final tags = _illustStore.illusts!.tags;
        for (var t1 in tags) {
          if (t.isRegexMatch(t1.name)) {
            return BanPage(
              name: "${I18n.of(context).tag}\n${t.name}\n",
              onPressed: () {
                setState(() {
                  tempView = true;
                });
              },
            );
          }
        }
        final allText = tags.map((e) => '#${e.name}').join('');
        if (t.isRegexMatch(allText)) {
          return BanPage(
            name: "${I18n.of(context).tag}\n${t.name}\n",
            onPressed: () {
              setState(() {
                tempView = true;
              });
            },
          );
        }
      }
    }
    return null;
  }

  bool supportTranslate = false;

  Future<void> supportTranslateCheck() async {
    if (!Platform.isAndroid) return;
    bool results = await SupportorPlugin.processText();
    if (mounted) {
      setState(() {
        supportTranslate = results;
      });
    }
  }

  Widget colorText(String text, BuildContext context) {
    return SelectionArea(
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.secondary,
          fontSize: 12,
        ),
      ),
    );
  }

  ScrollController scrollController = ScrollController();

  Widget _buildContent(BuildContext context, Illusts? data) {
    if (_illustStore.errorMessage != null) return _buildErrorContent(context);
    if (data == null)
      return Container(
        child: Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      );
    if (userStore == null) userStore = UserStore(data.user.id, null, data.user);
    return EasyRefresh(
      controller: _refreshController,
      header: PixezDefault.header(context),
      footer: PixezDefault.footer(context),
      onLoad: () {
        _aboutStore.next();
      },
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (userSetting.isBangs || ((data.width / data.height) > 5))
            SliverToBoxAdapter(
              child: Container(height: MediaQuery.of(context).padding.top),
            ),
          ..._buildPhotoList(data),
          SliverToBoxAdapter(key: _detailKey, child: SizedBox.shrink()),
          SliverToBoxAdapter(
            child: IllustDetailContent(
              illusts: data,
              userStore: userStore,
              illustStore: _illustStore,
              loadAbout: () {
                _loadAbout();
              },
            ),
          ),
          SliverGrid(
            delegate: SliverChildBuilderDelegate((
              BuildContext context,
              int index,
            ) {
              var list = _aboutStore.illusts
                  .map((element) => IllustStore(element.id, element))
                  .toList();
              return InkWell(
                onTap: () {
                  HapticUtil.selectionClick();
                  Leader.push(
                    context,
                    PictureListPage(
                      iStores: list,
                      lightingStore: null,
                      store: list[index],
                    ),
                  );
                },
                onLongPress: () async {
                  HapticUtil.heavy();
                  if (userSetting.longPressSaveConfirm) {
                    final result = await showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: Text(I18n.of(context).save),
                          content: Text(list[index].illusts?.title ?? ""),
                          actions: <Widget>[
                            TextButton(
                              child: Text(I18n.of(context).cancel),
                              onPressed: () {
                                Navigator.of(context).pop(false);
                              },
                            ),
                            TextButton(
                              child: Text(I18n.of(context).ok),
                              onPressed: () {
                                Navigator.of(context).pop(true);
                              },
                            ),
                          ],
                        );
                      },
                    );
                    if (!result) {
                      return;
                    }
                  }
                  final illust = _aboutStore.illusts[index];
                  saveStore.saveImage(illust);
                  await _autoBookmarkAfterSave(illust);
                },
                child: PixivImage(
                  _aboutStore.illusts[index].imageUrls.squareMedium,
                  enableMemoryCache: false,
                ),
              );
            }, childCount: _aboutStore.illusts.length),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPhotoList(Illusts data) {
    final height =
        ((data.height.toDouble() / data.width) *
        MediaQuery.of(context).size.width);
    return [
      if (data.type == "ugoira")
        SliverToBoxAdapter(
          child: NullHero(
            tag: widget.heroString,
            child: UgoiraLoader(id: widget.id, illusts: data),
          ),
        ),
      if (data.type != "ugoira")
        data.pageCount == 1
            ? SliverList(
                delegate: SliverChildBuilderDelegate((
                  BuildContext context,
                  int index,
                ) {
                  String url = data.illustDetailUrl;
                  if (data.type == "manga") {
                    url = data.managaDetailUrl;
                  }
                  Widget placeWidget = Container(height: height);
                  return InkWell(
                    onLongPress: () {
                      _pressSave(data, 0);
                    },
                    onTap: () {
                      Leader.push(
                        context,
                        PhotoZoomPage(
                          index: 0,
                          illusts: data,
                          illustStore: _illustStore,
                        ),
                      );
                    },
                    child: NullHero(
                      tag: widget.heroString,
                      child: PixivImage(
                        url,
                        // 注册到详情页专用协调器：限制详情大图并发
                        priorityIndex: 0,
                        width: MediaQuery.of(context).size.width,
                        // 按显示宽度解码：单图分支此前遗漏 memCacheWidth，
                        // 5000×7000 原图全尺寸解码可达 140MB 位图内存
                        memCacheWidth: _displayCacheWidth(
                          context,
                          url,
                          data.imageUrls.medium,
                        ),
                        cacheHeaderData: PixEzCacheHeaderData(
                          key: '${data.id}_0',
                          quality: IllustQualityExtension.fromValue(
                            data.type == "manga"
                                ? userSetting.mangaQuality
                                : userSetting.pictureQuality,
                          ),
                        ),
                        placeWidget: (url != data.imageUrls.medium)
                            ? PixivImage(
                                data.imageUrls.medium,
                                width: MediaQuery.of(context).size.width,
                                placeWidget: placeWidget,
                              )
                            : placeWidget,
                      ),
                    ),
                  );
                }, childCount: 1),
              )
            : SliverList(
                delegate: SliverChildBuilderDelegate((
                  BuildContext context,
                  int index,
                ) {
                  return InkWell(
                    onLongPress: () {
                      _pressSave(data, index);
                    },
                    onTap: () {
                      Leader.push(
                        context,
                        PhotoZoomPage(
                          index: index,
                          illusts: data,
                          illustStore: _illustStore,
                        ),
                      );
                    },
                    child: _buildIllustsItem(index, data, height),
                  );
                }, childCount: data.metaPages.length),
              ),
    ];
  }

  Center _buildErrorContent(BuildContext context) {
    return Center(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              ':(',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          Text('${_illustStore.errorMessage}', maxLines: 5),
          ElevatedButton(
            onPressed: () {
              _illustStore.fetch();
            },
            child: Text(I18n.of(context).refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildIllustsItem(int index, Illusts illust, double height) {
    if (illust.type == "manga") {
      String url = illust.managaDetailImageUrl(index);
      if (index == 0)
        return NullHero(
          child: PixivImage(
            url,
            // 注册到详情页专用协调器：限制详情大图并发
            priorityIndex: index,
            placeWidget: PixivImage(
              illust.metaPages[index].imageUrls!.medium,
              width: MediaQuery.of(context).size.width,
            ),
            cacheHeaderData: PixEzCacheHeaderData(
              key: '${illust.id}_${index}',
              quality: IllustQualityExtension.fromValue(
                userSetting.mangaQuality,
              ),
            ),
            width: MediaQuery.of(context).size.width,
            memCacheWidth: _displayCacheWidth(
              context,
              url,
              illust.metaPages[index].imageUrls!.medium,
            ),
          ),
          tag: widget.heroString,
        );
      return PixivImage(
        url,
        // 注册到详情页专用协调器：限制详情大图并发
        priorityIndex: index,
        width: MediaQuery.of(context).size.width,
        cacheHeaderData: PixEzCacheHeaderData(
          key: '${illust.id}_${index}',
          quality: IllustQualityExtension.fromValue(userSetting.mangaQuality),
        ),
        memCacheWidth: _displayCacheWidth(
          context,
          url,
          illust.metaPages[index].imageUrls!.medium,
        ),
        placeWidget: Container(
          height: height,
          child: Center(
            child: Text(
              '$index',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
      );
    }
    return index == 0
        ? (userSetting.pictureQuality >= 1
              ? NullHero(
                  child: PixivImage(
                    illust.illustDetailImageUrl(index),
                    // 注册到详情页专用协调器：限制详情大图并发
                    priorityIndex: index,
                    placeWidget: PixivImage(
                      illust.metaPages[index].imageUrls!.medium,
                    ),
                    cacheHeaderData: PixEzCacheHeaderData(
                      key: '${illust.id}_${index}',
                      quality: IllustQualityExtension.fromValue(
                        userSetting.pictureQuality,
                      ),
                    ),
                    memCacheWidth: _displayCacheWidth(
                      context,
                      illust.illustDetailImageUrl(index),
                      illust.metaPages[index].imageUrls!.medium,
                    ),
                  ),
                  tag: widget.heroString,
                )
              : NullHero(
                  child: PixivImage(
                    illust.metaPages[index].imageUrls!.medium,
                    cacheHeaderData: PixEzCacheHeaderData(
                      key: '${illust.id}_${index}',
                      quality: IllustQuality.medium,
                    ),
                  ),
                  tag: widget.heroString,
                ))
        : PixivImage(
            illust.illustDetailImageUrl(index),
            // 注册到详情页专用协调器：限制详情大图并发
            priorityIndex: index,
            cacheHeaderData: PixEzCacheHeaderData(
              key: '${illust.id}_${index}',
              quality: IllustQualityExtension.fromValue(
                userSetting.pictureQuality,
              ),
            ),
            memCacheWidth: _displayCacheWidth(
              context,
              illust.illustDetailImageUrl(index),
              illust.metaPages[index].imageUrls!.medium,
            ),
            placeWidget: Container(
              // 用传入的布局高度替代写死的 150：
              // 出图时高度一致，避免占位→真图切换的剧烈跳动
              height: height,
              child: Center(
                child: Text(
                  '$index',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ),
          );
  }

  Future _longPressTag(BuildContext context, Tags f) async {
    switch (await showDialog(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: "${f.name}",
                  style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (f.translatedName != null)
                  TextSpan(
                    text: "\n${"${f.translatedName}"}",
                    style: Theme.of(context).textTheme.bodyLarge!,
                  ),
              ],
            ),
          ),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 0);
              },
              child: Text(I18n.of(context).ban),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 1);
              },
              child: Text(I18n.of(context).bookmark),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 2);
              },
              child: Text(I18n.of(context).copy),
            ),
          ],
        );
      },
    )) {
      case 0:
        {
          muteStore.insertBanTag(
            BanTagPersist(name: f.name, translateName: f.translatedName ?? ""),
          );
        }
        break;
      case 1:
        {
          bookTagStore.bookTag(f.name);
        }
        break;
      case 2:
        {
          HapticUtil.light();
          await Clipboard.setData(ClipboardData(text: f.name));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: Duration(seconds: 1),
              content: Text(I18n.of(context).copied_to_clipboard),
            ),
          );
        }
    }
  }

  Widget buildRow(BuildContext context, Tags f) {
    return GestureDetector(
      onLongPress: () async {
        HapticUtil.heavy();
        await _longPressTag(context, f);
      },
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) {
              return ResultPage(
                word: f.name,
                translatedName: f.translatedName ?? "",
              );
            },
          ),
        );
      },
      child: Container(
        height: 25,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: const BorderRadius.all(Radius.circular(12.5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RichText(
              textAlign: TextAlign.start,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              text: TextSpan(
                text: "#${f.name}",
                children: [
                  TextSpan(
                    text: " ",
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall!.copyWith(fontSize: 12),
                  ),
                  if (f.translatedName != null)
                    TextSpan(
                      text: "${f.translatedName}",
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall!.copyWith(fontSize: 12),
                    ),
                ],
                style: Theme.of(context).textTheme.titleSmall!.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNameAvatar(BuildContext context, Illusts illust) {
    if (userStore == null)
      userStore = UserStore(illust.user.id, null, illust.user);
    return Observer(
      builder: (_) {
        Future.delayed(Duration(seconds: 2), () {
          _loadAbout();
        });
        return InkWell(
          onTap: () async {
            await _push2UserPage(context, illust);
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Padding(
                child: Hero(
                  tag:
                      illust.user.profileImageUrls.medium +
                      this.hashCode.toString(),
                  child: PainterAvatar(
                    url: illust.user.profileImageUrls.medium,
                    id: illust.user.id,
                    size: Size(32, 32),
                    onTap: () async {
                      await Leader.push(
                        context,
                        UsersPage(
                          id: illust.user.id,
                          userStore: userStore,
                          heroTag: this.hashCode.toString(),
                        ),
                      );
                      _illustStore.illusts!.user.isFollowed =
                          userStore!.isFollow;
                    },
                  ),
                ),
                padding: EdgeInsets.only(left: 16.0),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: <Widget>[
                      Hero(
                        tag: illust.user.name + this.hashCode.toString(),
                        child: SelectionArea(
                          child: Text(
                            illust.user.name,
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall!.color,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              UserFollowButton(
                id: illust.user.id,
                followed:
                    userStore?.isFollow ?? illust.user.isFollowed ?? false,
                onPressed: () async {
                  await userStore?.follow();
                  if (userStore?.isFollow != null) {
                    _illustStore.illusts?.user.isFollowed = userStore?.isFollow;
                  }
                },
                onConfirm: (follow, restrict) {
                  userStore?.followWithRestrict(follow, restrict);
                  if (userStore?.isFollow != null) {
                    _illustStore.illusts?.user.isFollowed = userStore?.isFollow;
                  }
                },
              ),
              SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }

  Future<void> _push2UserPage(BuildContext context, Illusts illust) async {
    await Leader.push(
      context,
      UsersPage(
        id: illust.user.id,
        userStore: userStore,
        heroTag: this.hashCode.toString(),
      ),
    );
    _illustStore.illusts!.user.isFollowed = userStore!.isFollow;
  }

  Future<void> _pressSave(Illusts illust, int index) async {
    HapticUtil.heavy();
    if (userSetting.illustDetailSaveSkipLongPress) {
      saveStore.saveImage(illust, index: index);
      await _autoBookmarkAfterSave(illust);
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c1) {
        return Container(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              illust.metaPages.isNotEmpty
                  ? ListTile(
                      title: Text(I18n.of(context).muti_choice_save),
                      leading: Icon(Icons.save),
                      onTap: () async {
                        Navigator.of(context).pop();
                        _showMutiChoiceDialog(illust, context);
                      },
                    )
                  : Container(),
              ListTile(
                leading: Icon(Icons.save_alt),
                onTap: () async {
                  Navigator.of(context).pop();
                  saveStore.saveImage(illust, index: index);
                  await _autoBookmarkAfterSave(illust);
                },
                onLongPress: () async {
                  Navigator.of(context).pop();
                  saveStore.saveImage(illust, index: index);
                },
                title: Text(I18n.of(context).save),
              ),
              ListTile(
                leading: Icon(Icons.cancel),
                onTap: () => Navigator.of(context).pop(),
                title: Text(I18n.of(context).cancel),
              ),
              Container(height: MediaQuery.of(c1).padding.bottom),
            ],
          ),
        );
      },
    );
  }

  Future _showMutiChoiceDialog(Illusts illust, BuildContext context) async {
    List<bool> indexs = [];
    bool allOn = false;
    for (int i = 0; i < illust.metaPages.length; i++) {
      indexs.add(false);
    }
    final result = await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16.0)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.8,
                child: Column(
                  children: [
                    Container(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(illust.title),
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        itemBuilder: (context, index) {
                          final data = illust.metaPages[index];
                          return Container(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: InkWell(
                                onTap: () {
                                  setDialogState(() {
                                    indexs[index] = !indexs[index];
                                  });
                                },
                                onLongPress: () {
                                  Leader.push(
                                    context,
                                    PhotoZoomPage(
                                      index: index,
                                      illusts: illust,
                                      illustStore: _illustStore,
                                    ),
                                  );
                                },
                                child: Stack(
                                  children: [
                                    PixivImage(
                                      data.imageUrls!.squareMedium,
                                      placeWidget: Container(
                                        child: Center(
                                          child: Text(index.toString()),
                                        ),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: Visibility(
                                        visible: indexs[index],
                                        child: Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Icon(
                                            Icons.check_circle,
                                            color: Colors.green,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                        itemCount: illust.metaPages.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Icon(
                        !allOn
                            ? Icons.check_circle_outline
                            : Icons.check_circle,
                      ),
                      title: Text(I18n.of(context).all),
                      onTap: () {
                        allOn = !allOn;
                        for (var i = 0; i < indexs.length; i++) {
                          indexs[i] = allOn;
                        }
                        setDialogState(() {});
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.save),
                      title: Text(I18n.of(context).save),
                      onTap: () async {
                        Navigator.of(context).pop("OK");
                        if (userSetting.starAfterSave &&
                            (_illustStore.state == 0)) {
                          bool success = await _illustStore.star(
                            restrict: userSetting.defaultPrivateLike
                                ? "private"
                                : "public",
                          );
                          if (success && userSetting.followAfterStar) {
                            await _illustStore.followAfterStar();
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    switch (result) {
      case "OK":
        {
          saveStore.saveChoiceImage(illust, indexs);
        }
    }
  }

  Future buildShowModalBottomSheet(BuildContext context, Illusts illusts) {
    final buttonBox = context.findRenderObject() as RenderBox?;
    final shareOrigin = buttonBox != null
        ? buttonBox.localToGlobal(Offset.zero) & buttonBox.size
        : null;
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final width =
            (MediaQuery.sizeOf(dialogContext).width - 24).clamp(0.0, 320.0);
        return SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, right: 12, left: 12),
              child: Material(
                color: Theme.of(dialogContext).colorScheme.surface,
                elevation: 8,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: width,
                    maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.75,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(height: 8),
                        _buildNameAvatar(dialogContext, illusts),
                        if (illusts.metaPages.isNotEmpty)
                          ListTile(
                            title: Text(I18n.of(dialogContext).muti_choice_save),
                            leading: Icon(Icons.save),
                            onTap: () async {
                              Navigator.of(dialogContext).pop();
                              _showMutiChoiceDialog(illusts, context);
                            },
                          ),
                        ListTile(
                          title: Text(I18n.of(dialogContext).copymessage),
                          leading: Icon(Icons.local_library),
                          onTap: () async {
                            final str =
                                userSetting.illustToShareInfoText(illusts);
                            await Clipboard.setData(ClipboardData(text: str));
                            BotToast.showText(
                              text: I18n.of(dialogContext).copied_to_clipboard,
                            );
                            Navigator.of(dialogContext).pop();
                          },
                        ),
                        ListTile(
                          title: Text(I18n.of(dialogContext).share),
                          leading: Icon(Icons.share),
                          onTap: () {
                            Navigator.of(dialogContext).pop();
                            SharePlus.instance.share(
                              ShareParams(
                                text:
                                    "https://www.pixiv.net/artworks/${widget.id}",
                                sharePositionOrigin: shareOrigin,
                              ),
                            );
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.link),
                          title: Text(I18n.of(dialogContext).link),
                          onTap: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text:
                                    "https://www.pixiv.net/artworks/${widget.id}",
                              ),
                            );
                            BotToast.showText(
                              text: I18n.of(dialogContext).copied_to_clipboard,
                            );
                            Navigator.of(dialogContext).pop();
                          },
                        ),
                        ListTile(
                          title: Text(I18n.of(dialogContext).ban),
                          leading: Icon(Icons.brightness_auto),
                          onTap: () {
                            muteStore.insertBanIllusts(
                              BanIllustIdPersist(
                                illustId: widget.id.toString(),
                                name: illusts.title,
                              ),
                            );
                            Navigator.of(dialogContext).pop();
                          },
                        ),
                        ListTile(
                          title: Text(I18n.of(dialogContext).report),
                          leading: Icon(Icons.report),
                          onTap: () async {
                            if (Platform.isAndroid) {
                              Navigator.of(dialogContext).pop();
                              await Reporter.show(
                                context,
                                () async => await muteStore.insertBanIllusts(
                                  BanIllustIdPersist(
                                    illustId: widget.id.toString(),
                                    name: illusts.title,
                                  ),
                                ),
                              );
                            } else {
                              await showDialog(
                                context: dialogContext,
                                builder: (context) {
                                  return AlertDialog(
                                    title: Text(I18n.of(context).report),
                                    content:
                                        Text(I18n.of(context).report_message),
                                    actions: <Widget>[
                                      TextButton(
                                        child: Text(I18n.of(context).cancel),
                                        onPressed: () {
                                          Navigator.of(context).pop("CANCEL");
                                        },
                                      ),
                                      TextButton(
                                        child: Text(I18n.of(context).ok),
                                        onPressed: () {
                                          Navigator.of(context).pop("OK");
                                        },
                                      ),
                                    ],
                                  );
                                },
                              );
                            }
                          },
                        ),
                        SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
            alignment: Alignment.topRight,
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _showBookMarkTag() async {
    HapticUtil.heavy();
    final result = await Leader.pushWithScaffold(
      context,
      TagForIllustPage(id: widget.id),
    );
    if (result is Map) {
      LPrinter.d(result);
      String restrict = result['restrict'];
      List<String>? tags = result['tags'];
      if (userSetting.saveAfterStar && (_illustStore.state == 0)) {
        saveStore.saveImage(_illustStore.illusts!);
      }
      bool success = await _illustStore.star(restrict: restrict, tags: tags, force: true);
      if (success && userSetting.followAfterStar) {
        await _illustStore.followAfterStar();
      }
    }
  }

  @override
  bool get wantKeepAlive => false;
}

class TextSelectionFix {
  static TextSelectionControls? buildControls(BuildContext context) {
    TextSelectionControls? controls = null;
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        controls ??= materialTextSelectionControls;
        break;
      case TargetPlatform.iOS:
        controls ??= cupertinoTextSelectionControls;
        break;
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        controls ??= desktopTextSelectionControls;
        break;
      case TargetPlatform.macOS:
        controls ??= cupertinoDesktopTextSelectionControls;
        break;
    }
    return controls;
  }
}
