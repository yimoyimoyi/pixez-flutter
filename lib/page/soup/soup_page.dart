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

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/main.dart';
import 'package:pixez/component/null_hero.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/models/am_article_block.dart';
import 'package:pixez/models/am_article_card.dart';
import 'package:pixez/models/amwork.dart';
import 'package:pixez/models/spotlight_response.dart';
import 'package:pixez/page/picture/illust_lighting_page.dart';
import 'package:pixez/page/picture/illust_store.dart';
import 'package:pixez/page/soup/soup_store.dart';
import 'package:url_launcher/url_launcher_string.dart';

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('封面已保存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Observer(builder: (context) {
        return NestedScrollView(
          body: buildBlocProvider(),
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return [
              if (widget.spotlight != null)
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 200.0,
                  flexibleSpace: FlexibleSpaceBar(
                    centerTitle: true,
                    title: Text(widget.spotlight!.pureTitle),
                    background: GestureDetector(
                      onLongPress: () => _saveCover(context),
                      child: NullHero(
                        tag: widget.heroTag,
                        child: PixivImage(
                          widget.spotlight!.thumbnail,
                          fit: BoxFit.cover,
                          height: 200,
                        ),
                      ),
                    ),
                  ),
                  actions: <Widget>[
                    IconButton(
                      icon: Icon(Icons.share),
                      onPressed: () async {
                        var url = widget.spotlight!.articleUrl;
                        await launchUrlString(url);
                      },
                    )
                  ],
                )
              else
                SliverAppBar()
            ];
          },
        );
      }),
    );
  }

  void _showLogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.bug_report, size: 18),
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
          TextButton(
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
                    fontSize: 22, fontWeight: FontWeight.bold, height: 1.4)),
            const SizedBox(height: 8),
          ],
          if (metaLine.isNotEmpty)
            Text(metaLine,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }

  Widget _buildArticleBlock(BuildContext context, AmArticleBlock block) {
    final textStyle = TextStyle(
      fontSize: 15,
      height: 1.8,
      color: Theme.of(context).colorScheme.onSurface,
    );
    switch (block.type) {
      case AmArticleBlockType.paragraph:
      case AmArticleBlockType.answer:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: _richText(block, textStyle),
        );
      case AmArticleBlockType.question:
        // 来信/提问用浅底色块与正文区分
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: _richText(block, textStyle),
        );
      case AmArticleBlockType.heading:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: _richText(block,
              const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, height: 1.4)),
        );
      case AmArticleBlockType.credit:
      case AmArticleBlockType.caption:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: _richText(block, TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline)),
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
    return InkWell(
      onTap: () {
        if (work != null) {
          _openWork(work);
        } else if (block.linkUrl.isNotEmpty) {
          launchUrlString(block.linkUrl);
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
                  child: Text(
                    block.text.isEmpty ? 'pixiv 作品' : block.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                if (work?.user != null)
                  Flexible(
                    child: Text(work!.user!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染文本类块的富文本:加粗(<b>)加粗、链接(<a>)主题色+下划线,
  /// 点击用浏览器打开;无富文本片段时回退纯文本
  Widget _richText(AmArticleBlock block, TextStyle baseStyle) {
    if (block.spans.isEmpty) {
      return Text(block.text, style: baseStyle);
    }
    final linkColor = Theme.of(context).colorScheme.primary;
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
              ..onTap = () => launchUrlString(s.link!))
            : null,
      ));
    }
    return Text.rich(TextSpan(children: children), style: baseStyle);
  }

  /// 文末相关特辑卡片块
  Widget _buildArticleCard(BuildContext context, AmArticleBlock block) {
    if (block.linkUrl.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openArticleCard(block),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
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
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ),
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

  /// 从作品链接尾段取 id 打开作品详情页(与作品流模式一致)
  void _openWork(AmWork work) {
    final link = work.arworkLink;
    if (link == null || link.isEmpty) return;
    final segments = Uri.parse(link).pathSegments;
    final id = segments.isNotEmpty ? int.tryParse(segments.last) : null;
    if (id == null) {
      launchUrlString(link);
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (BuildContext context) =>
            IllustLightingPage(id: id, store: IllustStore(id, null)),
      ),
    );
  }

  void _openArticleCard(AmArticleBlock block) {
    final idMatch = RegExp(r'/a/(\d+)').firstMatch(block.linkUrl);
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (BuildContext context) => SoupPage(
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
      ),
    );
  }

  /// 按屏幕逻辑宽度 × dpr 的解码上限(全宽图内存保护)
  int _screenWidthDpr(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return (size.width * MediaQuery.of(context).devicePixelRatio).round();
  }

  Widget buildBlocProvider() {
    // 加载中：显示加载动画，不显示错误
    if (_soupStore.isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    // 加载完成但无内容：显示错误（附浏览器逃生入口）
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PixivImage(
                    widget.spotlight!.thumbnail,
                    width: 200,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
                SizedBox(height: 12),
                Text(widget.spotlight!.pureTitle,
                    textAlign: TextAlign.center),
                SizedBox(height: 16),
              ],
              Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text('内容加载失败', style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text(
                _soupStore.errorMessage ?? '请检查网络连接后重试',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 16),
              OutlinedButton.icon(
                icon: Icon(Icons.open_in_browser, size: 16),
                label: Text('在浏览器中打开'),
                onPressed: () => launchUrlString(widget.url),
              ),
              // 调试日志入口仅 debug 模式展示（排查用）
              if (kDebugMode && _soupStore.logText.isNotEmpty) ...[
                SizedBox(height: 12),
                TextButton.icon(
                  icon: Icon(Icons.bug_report, size: 14),
                  label: Text('显示调试日志',
                      style: TextStyle(fontSize: 12)),
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

    // 特辑合集：展示特辑卡片列表
    if (_soupStore.amArticles.isNotEmpty) {
      return ListView.builder(
        itemBuilder: (BuildContext context, int index) {
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
          return InkWell(
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (BuildContext context) => SoupPage(
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
                ),
              );
            },
            child: Card(
              clipBehavior: Clip.antiAlias,
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                    trailing: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          );
        },
        itemCount: _soupStore.amArticles.length + 1,
      );
    }

    return ListView.builder(
      itemBuilder: (BuildContext context, int index) {
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
          return InkWell(
            onTap: () {
              int id = int.parse(Uri.parse(amWork.arworkLink!).pathSegments[
                  Uri.parse(amWork.arworkLink!).pathSegments.length - 1]);
              Navigator.of(context, rootNavigator: true)
                  .push(MaterialPageRoute(builder: (BuildContext context) {
                return IllustLightingPage(
                  id: id,
                  store: IllustStore(id, null),
                );
              }));
            },
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: PainterAvatar(
                      url: amWork.userImage!,
                      id: int.parse(Uri.parse(amWork.userLink!).pathSegments[
                          Uri.parse(amWork.userLink!).pathSegments.length - 1]),
                    ),
                    title: Text(amWork.title!),
                    subtitle: Text(amWork.user!),
                  ),
                  PixivImage(amWork.showImage!),
                ],
              ),
            ),
          );
        });
      },
      itemCount: _soupStore.amWorks.length + 1,
    );
  }
}
