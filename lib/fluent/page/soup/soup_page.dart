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

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/fluent/component/painter_avatar.dart';
import 'package:pixez/fluent/component/pixez_button.dart';
import 'package:pixez/fluent/component/pixiv_image.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/am_article_block.dart';
import 'package:pixez/models/am_article_card.dart';
import 'package:pixez/models/amwork.dart';
import 'package:pixez/models/spotlight_response.dart';
import 'package:pixez/fluent/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/picture/illust_store.dart';
import 'package:pixez/page/soup/soup_store.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waterfall_flow/waterfall_flow.dart';

class SoupPage extends StatefulWidget {
  final String url;
  final SpotlightArticle? spotlight;
  final String? heroTag;

  SoupPage({Key? key, required this.url, required this.spotlight, this.heroTag})
      : super(key: key);

  @override
  _SoupPageState createState() => _SoupPageState();
}

class _SoupPageState extends State<SoupPage> {
  final SoupStore _soupStore = SoupStore();
  bool _saving = false;

  @override
  void initState() {
    _soupStore.fetch(widget.url);
    super.initState();
  }

  @override
  void dispose() {
    // 释放原生 rhttp 客户端，避免句柄泄漏
    _soupStore.close();
    super.dispose();
  }

  /// 长按保存封面（防抖，按结果提示）
  Future<void> _saveCover(BuildContext context) async {
    if (_saving) return;
    _saving = true;
    try {
      await saveStore.saveImageByUrl(
        widget.spotlight!.thumbnail,
        widget.spotlight!.pureTitle,
      );
      if (mounted) {
        displayInfoBar(context, builder: (_, __) => const InfoBar(
          title: Text('封面已保存'),
          severity: InfoBarSeverity.success,
        ));
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (_, __) => InfoBar(
          title: Text('保存失败：$e'),
          severity: InfoBarSeverity.error,
        ));
      }
    } finally {
      _saving = false;
    }
  }

  void _showLogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Row(children: [
          Icon(FluentIcons.bug, size: 18),
          SizedBox(width: 8),
          Text('调试日志', style: TextStyle(fontSize: 16)),
        ]),
        content: Container(
          constraints: BoxConstraints(maxHeight: 400),
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(_soupStore.logText,
                style: TextStyle(fontSize: 10, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------------- 文章阅读模式(正文块渲染) ----------------

  /// 文章头部：无 spotlight(直达链接)时补文章标题,下方分类 · 日期
  Widget _buildArticleHeader(BuildContext context) {
    final title = _soupStore.articleTitle ?? '';
    final showTitle = widget.spotlight == null && title.isNotEmpty;
    final metaLine = [
      _soupStore.articleCategory ?? '',
      _soupStore.articleDate ?? '',
    ].where((s) => s.isNotEmpty).join(' · ');
    if (!showTitle && metaLine.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle) ...[
            Text(title,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w600, height: 1.4)),
            const SizedBox(height: 8),
          ],
          if (metaLine.isNotEmpty)
            Text(metaLine,
                style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF9E9E9E))),
        ],
      ),
    );
  }

  Widget _buildArticleBlock(BuildContext context, AmArticleBlock block) {
    final baseColor = FluentTheme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
    const textStyle = TextStyle(fontSize: 15, height: 1.8);
    switch (block.type) {
      case AmArticleBlockType.paragraph:
      case AmArticleBlockType.answer:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: _richText(block, textStyle.copyWith(color: baseColor)),
        );
      case AmArticleBlockType.question:
        // 来信/提问用卡片底色与正文区分
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Card(
            padding: const EdgeInsets.all(12),
            child: _richText(block, textStyle.copyWith(color: baseColor)),
          ),
        );
      case AmArticleBlockType.heading:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: _richText(block,
              const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, height: 1.4)
                  .copyWith(color: baseColor)),
        );
      case AmArticleBlockType.credit:
      case AmArticleBlockType.caption:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: _richText(block,
              const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
        );
      case AmArticleBlockType.image:
        if (block.imageUrl.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: PixivImage(
            block.imageUrl,
            width: double.infinity,
            // 插图按屏宽解码,避免全尺寸占用内存
            memCacheWidth: _screenWidthDpr(context),
          ),
        );
      case AmArticleBlockType.pixivIllust:
        return _buildArticleWork(context, block);
      case AmArticleBlockType.articleCard:
        return _buildArticleCard(context, block);
    }
  }

  /// 文章内嵌 pixiv 作品：整图展示,点击打开作品详情
  Widget _buildArticleWork(BuildContext context, AmArticleBlock block) {
    final work = block.work;
    final imageUrl = (work?.showImage ?? '').isNotEmpty
        ? work!.showImage!
        : block.imageUrl;
    final title = block.text.isEmpty ? 'pixiv 作品' : block.text;
    return PixEzButton(
      onPressed: () {
        if (work != null) {
          _openWork(work);
        } else if (block.linkUrl.isNotEmpty) {
          launchUrl(Uri.parse(block.linkUrl));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl.isNotEmpty)
            PixivImage(
              imageUrl,
              width: double.infinity,
              memCacheWidth: _screenWidthDpr(context),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                if (work?.user != null)
                  Flexible(
                    child: Text(work!.user!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染文本类块的富文本:加粗(<b>)、链接(<a>)强调色+下划线,
  /// 点击用浏览器打开;无富文本片段时回退纯文本
  Widget _richText(AmArticleBlock block, TextStyle baseStyle) {
    if (block.spans.isEmpty) {
      return Text(block.text, style: baseStyle);
    }
    final linkColor = FluentTheme.of(context).accentColor;
    final children = <TextSpan>[];
    for (final s in block.spans) {
      final hasLink = s.link != null && s.link!.isNotEmpty;
      children.add(TextSpan(
        text: s.text,
        style: (s.bold || hasLink)
            ? TextStyle(
                fontWeight: s.bold ? FontWeight.bold : null,
                color: hasLink ? linkColor : null,
                decoration: hasLink ? TextDecoration.underline : null,
              )
            : null,
        recognizer: hasLink
            ? (TapGestureRecognizer()
              ..onTap = () => launchUrl(Uri.parse(s.link!)))
            : null,
      ));
    }
    return RichText(
      text: TextSpan(style: baseStyle, children: children),
      textDirection: Directionality.of(context),
    );
  }

  /// 文末相关特辑卡片块
  Widget _buildArticleCard(BuildContext context, AmArticleBlock block) {
    if (block.linkUrl.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: PixEzButton(
        onPressed: () => _openArticleCard(block),
        child: Card(
          padding: EdgeInsets.zero,
          child: ListTile(
            leading: block.imageUrl.isEmpty
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: PixivImage(
                      block.imageUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                  ),
            title: Text(block.text,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: const Text('相关特辑'),
            trailing: const Icon(FluentIcons.chevron_right),
          ),
        ),
      ),
    );
  }

  /// 从作品链接尾段取 id 打开作品详情页(与作品流模式一致)
  void _openWork(AmWork work) {
    final link = work.arworkLink;
    if (link == null || link.isEmpty) return;
    final segments = Uri.parse(link).pathSegments;
    final id = segments.isNotEmpty ? int.tryParse(segments.last) : null;
    if (id == null) {
      launchUrl(Uri.parse(link));
      return;
    }
    Leader.push(
      context,
      IllustLightingPage(id: id, store: IllustStore(id, null)),
      icon: const Icon(FluentIcons.picture),
      title: Text(I18n.of(context).illust_id + ': $id'),
    );
  }

  void _openArticleCard(AmArticleBlock block) {
    final idMatch = RegExp(r'/a/(\d+)').firstMatch(block.linkUrl);
    Leader.push(
      context,
      SoupPage(
        url: block.linkUrl,
        spotlight: SpotlightArticle(
          id: int.tryParse(idMatch?.group(1) ?? '') ?? 0,
          title: block.text,
          pureTitle: block.text,
          thumbnail: block.imageUrl,
          articleUrl: block.linkUrl,
          publishDate: DateTime.now(),
        ),
      ),
      icon: const Icon(FluentIcons.all_apps),
      title: Text(block.text),
    );
  }

  /// 集合卡副标题:分类 · 日期(两者皆空时不占行)
  Widget? _cardSubtitle(AmArticleCard card) {
    final parts = [
      if (card.category.isNotEmpty) card.category,
      if (card.date.isNotEmpty) card.date,
    ].join(' · ');
    return parts.isEmpty ? null : Text(parts);
  }

  /// 按屏幕逻辑宽度 × dpr 的解码上限(全宽图内存保护)
  int _screenWidthDpr(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return (size.width * MediaQuery.of(context).devicePixelRatio).round();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text(widget.spotlight?.pureTitle ?? ''),
        commandBar: widget.spotlight != null
            ? CommandBar(
                mainAxisAlignment: MainAxisAlignment.end,
                primaryItems: [
                  CommandBarButton(
                    icon: Icon(FluentIcons.share),
                    onPressed: () async {
                      var url = widget.spotlight!.articleUrl;
                      await launchUrl(Uri.tryParse(url)!);
                    },
                  )
                ],
              )
            : null,
      ),
      content: Observer(builder: (context) {
        return buildBlocProvider();
      }),
    );
  }

  Widget buildBlocProvider() {
    if (_soupStore.isLoading) {
      return Center(child: ProgressRing());
    }
    if (_soupStore.amWorks.isEmpty &&
        _soupStore.amArticles.isEmpty &&
        _soupStore.articleBlocks.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.spotlight != null) ...[
                GestureDetector(
                  onLongPress: () => _saveCover(context),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: PixivImage(
                      widget.spotlight!.thumbnail,
                      width: 200,
                      height: 120,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                SizedBox(height: 12),
                Text(widget.spotlight!.pureTitle,
                    textAlign: TextAlign.center),
                SizedBox(height: 16),
              ],
              Icon(FluentIcons.cloud, size: 48),
              SizedBox(height: 12),
              Text('内容加载失败'),
              SizedBox(height: 4),
              Text(
                _soupStore.errorMessage ?? '请检查网络连接后重试',
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              Button(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.open_in_new_window, size: 14),
                    SizedBox(width: 6),
                    Text('在浏览器中打开'),
                  ],
                ),
                onPressed: () => launchUrl(Uri.parse(widget.url)),
              ),
              // 调试日志入口仅 debug 模式展示（排查用）
              if (kDebugMode && _soupStore.logText.isNotEmpty) ...[
                SizedBox(height: 12),
                Button(
                  child: Text('显示调试日志'),
                  onPressed: () => _showLogDialog(context),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 文章阅读模式：专访/专栏/图文混排等正文块按顺序渲染
    if (_soupStore.articleBlocks.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _soupStore.articleBlocks.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) return _buildArticleHeader(context);
          return _buildArticleBlock(context,
              _soupStore.articleBlocks[index - 1]);
        },
      );
    }
    final count = (MediaQuery.of(context).orientation == Orientation.portrait)
        ? userSetting.crossCount
        : userSetting.hCrossCount;

    if (_soupStore.amArticles.isNotEmpty) {
      return CustomScrollView(
        slivers: [
          SliverWaterfallFlow(
            gridDelegate: SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
            ),
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                if (index == 0) {
                  if (_soupStore.description == null ||
                      _soupStore.description!.isEmpty) {
                    return Container(height: 1);
                  }
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(_soupStore.description ?? ''),
                    ),
                  );
                }
                AmArticleCard card = _soupStore.amArticles[index - 1];
                return PixEzButton(
                  child: Card(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (card.thumbnail.isNotEmpty)
                          PixivImage(
                            card.thumbnail,
                            width: double.infinity,
                            height: 180,
                            fit: BoxFit.cover,
                          ),
                        ListTile(
                          title: Text(
                            card.title,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: _cardSubtitle(card),
                          trailing: const Icon(FluentIcons.chevron_right),
                        ),
                      ],
                    ),
                  ),
                  onPressed: () {
                    Leader.push(
                      context,
                      SoupPage(
                        url: card.articleUrl,
                        spotlight: SpotlightArticle(
                          id: int.tryParse(card.id) ?? 0,
                          title: card.title,
                          pureTitle: card.title,
                          thumbnail: card.thumbnail,
                          articleUrl: card.articleUrl,
                          publishDate: DateTime.tryParse(
                                  card.date.replaceAll('.', '-')) ??
                              DateTime.now(),
                        ),
                      ),
                      icon: const Icon(FluentIcons.all_apps),
                      title: Text(card.title),
                    );
                  },
                );
              },
              childCount: _soupStore.amArticles.length + 1,
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        SliverWaterfallFlow(
          gridDelegate: SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
          ),
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) {
              return Builder(builder: (context) {
                if (index == 0) {
                  if (_soupStore.description == null ||
                      _soupStore.description!.isEmpty)
                    return Container(
                      height: 1,
                    );
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(_soupStore.description ?? ''),
                    ),
                  );
                }
                AmWork amWork = _soupStore.amWorks[index - 1];
                return PixEzButton(
                  child: Card(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        PixivImage(amWork.showImage!),
                        ListTile(
                          leading: PainterAvatar(
                            url: amWork.userImage!,
                            id: int.parse(Uri.parse(amWork.userLink!)
                                .pathSegments[Uri.parse(amWork.userLink!)
                                    .pathSegments
                                    .length -
                                1]),
                          ),
                          title: Text(amWork.title!),
                          subtitle: Text(amWork.user!),
                        ),
                      ],
                    ),
                  ),
                  onPressed: () {
                    int id = int.parse(Uri.parse(amWork.arworkLink!)
                            .pathSegments[
                        Uri.parse(amWork.arworkLink!).pathSegments.length - 1]);
                    Leader.push(
                      context,
                      IllustLightingPage(
                        id: id,
                        store: IllustStore(id, null),
                      ),
                      icon: Icon(FluentIcons.picture),
                      title: Text(I18n.of(context).illust_id + ': ${id}'),
                    );
                  },
                );
              });
            },
            childCount: _soupStore.amWorks.length + 1,
          ),
        )
      ],
    );
  }
}
