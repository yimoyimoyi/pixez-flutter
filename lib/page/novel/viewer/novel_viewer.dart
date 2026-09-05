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

import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/component/selectable_html.dart';
import 'package:pixez/component/selection_tools.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/ban_tag.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/novel_web_response.dart';
import 'package:pixez/page/comment/comment_page.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/page/novel/search/novel_result_page.dart';
import 'package:pixez/page/novel/series/novel_series_page.dart';
import 'package:pixez/page/novel/user/novel_users_page.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/page/hello/setting/translation_setting_page.dart';
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';
import 'package:pixez/saf_plugin.dart';
import 'package:pixez/supportor_plugin.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as Path;

class NovelViewerPage extends StatefulWidget {
  final int id;
  final NovelStore? novelStore;

  const NovelViewerPage({Key? key, required this.id, this.novelStore})
    : super(key: key);

  @override
  _NovelViewerPageState createState() => _NovelViewerPageState();
}

class _NovelViewerPageState extends State<NovelViewerPage> {
  ScrollController? _controller;
  late NovelStore _novelStore;
  ReactionDisposer? _offsetDisposer;
  double _localOffset = 0.0;
  bool supportTranslate = false;
  String _selectedText = "";
  NovelSpansGenerator novelSpansGenerator = NovelSpansGenerator();

  Future<void> initMethod() async {
    if (!Platform.isAndroid) return;
    bool results = await SupportorPlugin.processText();
    if (mounted) {
      setState(() {
        supportTranslate = results;
      });
    }
  }

  @override
  void initState() {
    _novelStore = widget.novelStore ?? NovelStore(widget.id, null);
    _offsetDisposer = reaction((_) => _novelStore.bookedOffset, (_) {
      LPrinter.d("jump to ${_novelStore.bookedOffset}");
      _controller?.jumpTo(_novelStore.bookedOffset);
    });
    _novelStore.fetch();
    super.initState();
    initMethod();
  }

  @override
  void dispose() {
    _offsetDisposer?.call();
    if (_novelStore.positionBooked) {
      _novelStore.bookPosition(_localOffset);
    }
    _novelStore.cancelTranslateFullText(); // 离开阅读页取消后续批次（在途批完成写缓存可复用）
    _controller?.dispose();
    super.dispose();
  }

  final double leading = 0.9;
  final double textLineHeight = 2;
  final double fontSize = 16;
  TextStyle? _textStyle;

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        _textStyle = Theme.of(
          context,
        ).textTheme.bodyLarge!.copyWith(fontSize: userSetting.novelFontsize);
        if (_novelStore.errorMessage != null) {
          return _buildErrorContent(context);
        }
        if (_novelStore.novelTextResponse != null &&
            _novelStore.novel != null) {
          _textStyle =
              _textStyle ?? Theme.of(context).textTheme.bodyLarge!.copyWith();
          if (_controller == null) {
            LPrinter.d("init Controller ${_novelStore.bookedOffset}");
            _controller = ScrollController(
              initialScrollOffset: _novelStore.bookedOffset,
            );
            _controller?.addListener(() {
              if (_controller!.hasClients) _localOffset = _controller!.offset;
            });
          }
          return Scaffold(
            appBar: _buildAppbar(context),
            extendBodyBehindAppBar: true,
            body: _buildBody(context),
          );
        }
        return Scaffold(
          appBar: AppBar(elevation: 0.0, backgroundColor: Colors.transparent),
          body: Container(child: Center(child: CircularProgressIndicator())),
        );
      },
    );
  }

  Scaffold _buildErrorContent(BuildContext context) {
    return Scaffold(
      appBar: AppBar(elevation: 0.0),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: Text(
                    ':(',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                _novelStore.fetch();
              },
              child: Text(I18n.of(context).retry),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('${_novelStore.errorMessage}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.all(0),
      controller: _controller,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildHeader(context);
        } else if (index == _novelStore.spans.length + 1) {
          return _buildCommentButton(context);
        } else if (index == _novelStore.spans.length + 2) {
          return Container(height: 10 + MediaQuery.of(context).padding.bottom);
        } else {
          return _buildSpanText(context, index - 1, _novelStore.spans);
        }
      },
      itemCount: 3 + _novelStore.spans.length,
    );
  }

  AppBar _buildAppbar(BuildContext context) {
    return AppBar(
      elevation: 0.0,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: Theme.of(context).textTheme.bodyLarge!.color,
        ),
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
      title: Text(
        _novelStore.novelTextResponse!.text.length.toString(),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      backgroundColor: Colors.transparent,
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.home_outlined, size: 22),
          onPressed: () => Navigator.of(context)
              .popUntil((route) => route.isFirst),
          tooltip: '主页',
        ),
        NovelBookmarkButton(novel: _novelStore.novel!),
        IconButton(
          onPressed: () {
            if (_novelStore.positionBooked)
              _novelStore.deleteBookPosition();
            else
              _novelStore.bookPosition(_controller!.offset);
          },
          icon: Icon(Icons.history),
          color: Theme.of(context).textTheme.bodyLarge!.color!.withAlpha(
            _novelStore.positionBooked ? 225 : 120,
          ),
        ),
        Builder(
          builder: (context) {
            return IconButton(
              icon: Icon(
                Icons.more_vert,
                color: Theme.of(context).textTheme.bodyLarge!.color,
              ),
              onPressed: () {
                _showMessage(context);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildSpanText(
    BuildContext context,
    int index,
    List<NovelSpansData> spanDatas,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: SelectionArea(
        onSelectionChanged: (value) {
          _selectedText = value?.plainText ?? "";
        },
        contextMenuBuilder: (context, editableTextState) {
          return _buildSelectionMenu(editableTextState, context);
        },
        // span 级 Observer：译文到达（store.translated 变更）只重建对应 span，
        // 滚动位置不受影响；页面级 Observer 不读翻译 observable
        child: Observer(
          builder: (_) => Text.rich(
            novelSpansGenerator.novelSpansDatatoInlineSpan(
              context,
              spanDatas[index],
            ),
            style: _textStyle,
            textHeightBehavior: TextHeightBehavior(
              applyHeightToLastDescent: true,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommentButton(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
      child: Center(
        child: TextButton(
          onPressed: () {
            Leader.push(
              context,
              CommentPage(id: _novelStore.id, type: CommentArtWorkType.NOVEL),
            );
          },
          child: Text(
            '${I18n.of(context).view_comment}(${_novelStore.novel?.totalComments ?? 0})',
          ),
        ),
      ),
    );
  }

  /// 小说标题"显示译文"开关（手动触发语义：点击翻译后显示，再点切回原文）
  bool _titleShowTranslated = false;

  Future<void> _toggleNovelTitleTranslation(BuildContext context) async {
    final service = TranslationService.instance;
    final title = _novelStore.novel!.title;
    setState(() {
      _titleShowTranslated = !_titleShowTranslated;
    });
    if (_titleShowTranslated && title.trim().isNotEmpty) {
      final ok = await service.translateTitle(title);
      if (!ok && mounted) {
        BotToast.showText(
          text:
              I18n.of(context).translation_failed +
              service.describeLastError(),
        );
      }
    }
  }

  /// 小说标题行：译文/原文 + "翻译/原文"切换按钮。
  /// 局部 Observer：译文到达只重建标题行，不影响正文列表；
  /// 未开启标题翻译时保持老布局（无按钮）。
  Widget _buildNovelTitleRow(BuildContext context) {
    return Observer(builder: (_) {
      final service = TranslationService.instance;
      const type = TranslateContentType.title;
      final title = _novelStore.novel!.title;
      final pending = service.isPendingOf(title, type);
      final translated = service.translatedOf(title, type);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              _titleShowTranslated ? (translated ?? title) : title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (service.isTypeEnabled(type))
            SizedBox(
              height: 32,
              child: TextButton.icon(
                icon: pending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.translate, size: 16),
                label: Text(
                  _titleShowTranslated
                      ? I18n.of(context).translation_show_original
                      : I18n.of(context).translate,
                  style: const TextStyle(fontSize: 13),
                ),
                onPressed: () => _toggleNovelTitleTranslation(context),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      child: Column(
        children: [
          Container(height: 100),
          Center(
            child: Container(
              width: 200,
              height: 280,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey.shade200,
              ),
              child: PixivImage(_novelStore.novel!.imageUrls.qualityUrl,
                  fit: BoxFit.cover),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              right: 8.0,
              top: 12.0,
              bottom: 8.0,
            ),
            child: _buildNovelTitleRow(context),
          ),
          if (_novelStore.novel?.series.id != null)
            Padding(
              padding: const EdgeInsets.only(
                left: 16.0,
                right: 16.0,
                top: 0.0,
                bottom: 0.0,
              ),
              child: InkWell(
                onTap: () {
                  Leader.push(
                    context,
                    NovelSeriesPage(_novelStore.novel!.series.id!),
                  );
                },
                child: Text(
                  "Series:${_novelStore.novel!.series.title}",
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
          //MARK DETAIL NUM,
          _buildNumItem(_novelStore.novel!),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              "${_novelStore.novel!.createDate}",
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 8.0,
              horizontal: 16.0,
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 0,
              children: [
                if (_novelStore.novel!.NovelAIType == 2)
                  Text(
                    "${I18n.of(context).ai_generated}",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                for (var f in _novelStore.novel!.tags) buildRow(context, f),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SelectionArea(
                  onSelectionChanged: (value) {
                    _selectedText = value?.plainText ?? "";
                  },
                  contextMenuBuilder: (context, editableTextState) {
                    return _buildSelectionMenu(editableTextState, context);
                  },
                  child: SelectableHtml(
                    data: _novelStore.novel?.caption ?? "",
                    // 简介翻译：与图片详情一致，组件内自带"翻译/原文"按钮与失败提示
                    translateType: TranslateContentType.caption,
                    translateId: 'novel:${_novelStore.novel?.id}',
                  ),
                ),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Leader.push(
                context,
                CommentPage(id: _novelStore.id, type: CommentArtWorkType.NOVEL),
              );
            },
            child: Text(
              '${I18n.of(context).view_comment}(${_novelStore.novel?.totalComments ?? 0})',
            ),
          ),
        ],
      ),
    );
  }

  AdaptiveTextSelectionToolbar _buildSelectionMenu(
    SelectableRegionState editableTextState,
    BuildContext context,
  ) {
    final List<ContextMenuButtonItem> buttonItems =
        editableTextState.contextMenuButtonItems;
    // 应用内翻译（通用类型；未开启配置时不插入）
    addTranslateMenuItem(buttonItems, context: context, selectionText: _selectedText);
    if (supportTranslate) {
      buttonItems.insert(
        buttonItems.length,
        ContextMenuButtonItem(
          label: I18n.of(context).translate,
          onPressed: () async {
            final selectionText = _selectedText;
            if (Platform.isIOS) {
              final box = context.findRenderObject() as RenderBox?;
              final pos = box != null
                  ? box.localToGlobal(Offset.zero) & box.size
                  : null;
              SharePlus.instance.share(
                ShareParams(text: selectionText, sharePositionOrigin: pos),
              );
              return;
            }
            await SupportorPlugin.start(selectionText);
            ContextMenuController.removeAny();
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setB) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Container(
                        child: Icon(Icons.text_fields),
                        margin: EdgeInsets.only(left: 16),
                      ),
                      Container(
                        child: Text(_textStyle!.fontSize!.toInt().toString()),
                        margin: EdgeInsets.only(left: 16),
                      ),
                      Expanded(
                        child: Slider(
                          value: _textStyle!.fontSize! / 32,
                          onChanged: (v) {
                            setB(() {
                              _textStyle = _textStyle!.copyWith(
                                fontSize: v * 32,
                              );
                            });
                            userSetting.setNovelFontsizeWithoutSave(v * 32);
                          },
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  // 全文翻译（novelBody）：进度/取消/预估
                  _buildNovelTranslateSection(context),
                ],
              ),
            );
          },
        );
      },
    );
    userSetting.setNovelFontsize(_textStyle!.fontSize!);
  }

  /// 全文翻译区块：未开启 → 引导；未开始 → 按钮+预估；翻译中 → 进度+取消
  Widget _buildNovelTranslateSection(BuildContext context) {
    final service = TranslationService.instance;
    const type = TranslateContentType.novelBody;
    if (!service.isTypeEnabled(type)) {
      return Center(
        child: TextButton.icon(
          icon: const Icon(Icons.translate, size: 18),
          label: Text(I18n.of(context).translation_novel_not_enabled),
          onPressed: () => Leader.push(context, const TranslationSettingPage()),
        ),
      );
    }
    return Observer(
      builder: (_) {
        final store = _novelStore;
        final total = store.novelTotalSpans;
        final done = store.novelTranslatedSpans;
        final cfg = service.config;
        if (!store.novelTranslating) {
          // 未开始/已结束：预估（按当前 spans 统计）
          final stats = novelTranslatableStats(store.spans);
          final batches = stats.charsCount == 0
              ? 0
              : (stats.charsCount + cfg.novelBatchChars - 1) ~/ cfg.novelBatchChars;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    stats.parasCount == 0
                        ? I18n.of(context).translation_no_novel_content
                        : I18n.of(context).translation_novel_estimate(
                            stats.parasCount, batches, batches * 6),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                if (store.novelTranslateDone && total > 0 && done >= total)
                  if (store.novelFailedSpans > 0)
                    // 有失败段：显示失败数 + 具体原因 + 重试按钮（成功段缓存 miss 秒过）
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          I18n.of(context)
                              .translation_novel_failed(store.novelFailedSpans),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
                        ),
                        Text(
                          TranslationService.instance.describeLastError(),
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(
                              I18n.of(context).translation_retry_failed),
                          onPressed: () => store.translateFullText(),
                        ),
                      ],
                    )
                  else
                    Text(
                      I18n.of(context).translation_novel_done,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary),
                    )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.translate, size: 18),
                    label: Text(I18n.of(context).translation_full_novel),
                    onPressed: () => store.translateFullText(),
                  ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text('$done / $total · '
                        '${I18n.of(context).translation_novel_batch_estimate(
                            total == 0 ? 0 : (store.novelTotalChars == 0
                                ? 0
                                : (store.novelTotalChars + cfg.novelBatchChars - 1) ~/ cfg.novelBatchChars),
                            _novelTranslateMinutes(done, total))}',
                        style: const TextStyle(fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: () => store.cancelTranslateFullText(),
                    child: Text(I18n.of(context).cancel),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// 按已处理段落占比估算剩余分钟（每分钟 10 批 × 6s）
  int _novelTranslateMinutes(int done, int total) {
    if (total <= 0) return 0;
    final ratio = (total - done) / total;
    return (ratio * 8).ceil(); // 粗略：每 8 批约 1 分钟
  }

  Future _longPressTag(BuildContext context, Tag f) async {
    switch (await showDialog(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: Text(f.name),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 0);
              },
              child: Text(I18n.of(context).ban),
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
          await muteStore.insertBanTag(
            BanTagPersist(name: f.name, translateName: f.translatedName ?? ""),
          );
          Navigator.of(context).pop();
        }
        break;
      case 2:
        {
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

  Widget buildRow(BuildContext context, Tag f) {
    return GestureDetector(
      onLongPress: () async {
        _longPressTag(context, f);
      },
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) {
              return NovelResultPage(
                word: f.name,
                translatedName: f.translatedName ?? "",
              );
            },
          ),
        );
      },
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          text: "#${f.name}",
          children: [
            TextSpan(text: " ", style: Theme.of(context).textTheme.bodySmall),
            TextSpan(
              text: "${f.translatedName ?? "~"}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      ),
    );
  }

  Widget _buildNumItem(Novel novel) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 0,
        children: [
          Text(I18n.of(context).total_bookmark),
          Text(
            "${novel.totalBookmarks}",
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(I18n.of(context).total_view),
          ),
          Text(
            "${novel.totalView}",
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
    );
  }

  Future _showMessage(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16.0)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListTile(
                subtitle: Text(_novelStore.novel!.user.name, maxLines: 2),
                title: Text(_novelStore.novel!.title, maxLines: 2),
                leading: Container(
                  child: PainterAvatar(
                    url: _novelStore.novel!.user.profileImageUrls.medium,
                    id: _novelStore.novel!.user.id,
                    size: Size(40, 40),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) {
                            return NovelUsersPage(
                              id: _novelStore.novel!.user.id,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(context).pre),
              ),
              buildListTile(
                _novelStore.novelTextResponse!.seriesNavigation?.prevNovel,
              ),
              Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(context).next),
              ),
              buildListTile(
                _novelStore.novelTextResponse!.seriesNavigation?.nextNovel,
              ),
              if (Platform.isAndroid)
                ListTile(
                  title: Text(I18n.of(context).export),
                  leading: Icon(Icons.folder_zip),
                  onTap: () {
                    _export();
                  },
                ),
              ListTile(
                title: Text(I18n.of(context).translation_full_novel),
                leading: const Icon(Icons.translate),
                onTap: () {
                  Navigator.of(context).pop();
                  _showSettings(context);
                },
              ),
              ListTile(
                title: Text(I18n.of(context).setting),
                leading: Icon(Icons.settings),
                onTap: () {
                  Navigator.of(context).pop();
                  _showSettings(context);
                },
              ),
              Builder(
                builder: (context) {
                  return ListTile(
                    title: Text(I18n.of(context).share),
                    leading: Icon(Icons.share),
                    onTap: () {
                      Navigator.of(context).pop();
                      final box = context.findRenderObject() as RenderBox?;
                      final pos = box != null
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null;
                      final link =
                          "https://www.pixiv.net/novel/show.php?id=${widget.id}";
                      SharePlus.instance.share(
                        ShareParams(text: link, sharePositionOrigin: pos),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget buildListTile(PrevNovel? series) {
    if (series == null) return ListTile(title: Text("no more"));
    return ListTile(
      title: Text(
        series.title ?? series.contentOrder,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      enabled: series.viewable,
      onTap: series.viewable
          ? () {
              Navigator.of(context, rootNavigator: true).pushReplacement(
                MaterialPageRoute(
                  builder: (BuildContext context) => NovelViewerPage(
                    id: series.id,
                    novelStore: NovelStore(series.id, null),
                  ),
                ),
              );
            }
          : null,
    );
  }

  void _export() async {
    if (_novelStore.novelTextResponse == null) return;
    if (Platform.isAndroid) {
      // final path = await getExternalStorageDirectory();
      // if (path == null) return;
      // final dirPath = Path.join(path.path, "novel_export");
      // final dir = Directory(dirPath);
      // if (!dir.existsSync()) {
      //   dir.createSync(recursive: true);
      // }
      // final allPath = Path.join(dirPath, "All");
      // final allDir = Directory(allPath);
      // if (!allDir.existsSync()) {
      //   allDir.createSync(recursive: true);
      // }
      // final novelDirPath =
      //     Path.join(dirPath, _novelStore.novel!.title.trim().toLegal());
      // final novelDir = Directory(novelDirPath);
      // if (!novelDir.existsSync()) {
      //   novelDir.createSync(recursive: true);
      // }
      // final fileInAllPath = Path.join(
      //     allPath, "${_novelStore.novel!.title.trim().toLegal()}.txt");
      // final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      // final resultFile = File(filePath);
      // final data = _novelStore.novelTextResponse!.text;
      // resultFile.writeAsStringSync(data);
      // File(fileInAllPath).writeAsStringSync(data);
      // BotToast.showText(text: "export ${filePath}");
      final data = _novelStore.novelTextResponse!.text;
      final uri = await SAFPlugin.createFile(
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
        "application/txt",
      );
      await SAFPlugin.writeUri(uri!, utf8.encode(data));
      BotToast.showText(text: "export success");
    } else if (Platform.isIOS) {
      final path = await getApplicationDocumentsDirectory();
      final dirPath = Path.join(path.path, "novel_export");
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final allPath = Path.join(dirPath, "All");
      final allDir = Directory(allPath);
      if (!allDir.existsSync()) {
        allDir.createSync(recursive: true);
      }
      final novelDirPath = Path.join(
        dirPath,
        _novelStore.novel!.title.trim().toLegal(),
      );
      final novelDir = Directory(novelDirPath);
      if (!novelDir.existsSync()) {
        novelDir.createSync(recursive: true);
      }
      final fileInAllPath = Path.join(
        allPath,
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
      );
      final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      final resultFile = File(filePath);
      final data = _novelStore.novelTextResponse!.text;
      resultFile.writeAsStringSync(data);
      File(fileInAllPath).writeAsStringSync(data);
      LPrinter.d("path: $filePath");
      BotToast.showText(text: "export ${filePath}");
    }
  }
}
