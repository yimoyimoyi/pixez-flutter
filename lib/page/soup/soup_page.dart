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
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/main.dart';
import 'package:pixez/component/null_hero.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixiv_image.dart';
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

  Widget buildBlocProvider() {
    // 加载中：显示加载动画，不显示错误
    if (_soupStore.isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    // 加载完成但无内容：显示错误或专栏提示
    if (_soupStore.amWorks.isEmpty && _soupStore.amArticles.isEmpty) {
      final isText = _soupStore.isTextArticle;
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
              Icon(
                isText ? Icons.article_outlined : Icons.cloud_off,
                size: 48,
                color: Colors.grey,
              ),
              SizedBox(height: 12),
              Text(
                isText ? '文字专栏特辑' : '正文加载失败',
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 4),
              Text(
                _soupStore.errorMessage ?? '请检查网络连接后重试',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              if (isText) ...[
                SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: Icon(Icons.open_in_browser, size: 16),
                  label: Text('在浏览器中打开'),
                  onPressed: () => launchUrlString(widget.url),
                ),
              ],
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
                    subtitle: Text(
                      '${card.category}${card.date.isNotEmpty ? ' · ${card.date}' : ''}',
                    ),
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
