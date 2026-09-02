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

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:mobx/mobx.dart';
import 'package:html/parser.dart' show parse;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/am_article_block.dart';
import 'package:pixez/models/am_article_card.dart';
import 'package:pixez/models/amwork.dart';
import 'package:rhttp/rhttp.dart' as r;
import 'package:html/dom.dart';

part 'soup_store.g.dart';

class SoupStore = _SoupStoreBase with _$SoupStore;

abstract class _SoupStoreBase with Store {
  @observable
  late Dio dio;

  /// 视觉特辑作品流模式下的作品(视觉特辑/老布局)
  ObservableList<AmWork> amWorks = ObservableList();

  /// 合集/栏目列表页的卡片(单篇特辑入口,全部类型放行)
  ObservableList<AmArticleCard> amArticles = ObservableList();

  /// 文章阅读模式的正文块(专访/专栏/图文混排等非纯作品页)
  ObservableList<AmArticleBlock> articleBlocks = ObservableList();

  @observable
  String? articleTitle;

  @observable
  String? articleCategory;

  @observable
  String? articleDate;

  bool get isCollection => amArticles.isNotEmpty;

  @observable
  String? description;

  @observable
  String? errorMessage;

  @observable
  String logText = '';

  @observable
  bool isLoading = false;

  void _log(String msg) {
    LPrinter.d('SoupStore: $msg');
    // 限制日志长度（调试面板展示用），防止无限增长
    logText = '${logText}$msg\n';
    if (logText.length > 4000) {
      logText = logText.substring(logText.length - 3000);
    }
  }

  // 原生 rhttp 客户端复用单例，避免每次 fetch 新建泄漏原生句柄
  r.RhttpCompatibleClient? _compatClient;

  /// 释放原生客户端（页面销毁时调用）
  void close() {
    final client = _compatClient;
    _compatClient = null;
    if (client != null) {
      try {
        client.close();
      } catch (e) {
        LPrinter.d('SoupStore close error: $e');
      }
    }
  }

  Future<Dio> _createDio() async {
    _log('creating rhttp client...');
    _compatClient ??= await r.RhttpCompatibleClient.create(
      settings: r.ClientSettings(
        httpVersionPref: r.HttpVersionPref.http1_1,
        tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
        dnsSettings: r.DnsSettings.static(
          // 复用 Hoster 的 API 源站 IP 池（与 pixivision 同一组 IP，避免重复维护）
          overrides: {
            'www.pixivision.net': Hoster.apiPool(),
          },
        ),
      ),
    );
    final client = _compatClient!;
    _log('rhttp client created');
    final d = Dio(BaseOptions(
      connectTimeout: Duration(seconds: 10),
      receiveTimeout: Duration(seconds: 15),
      headers: {
        HttpHeaders.acceptLanguageHeader: userSetting.languageNum < 5
            ? 'zh-CN'
            : "en-US",
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        HttpHeaders.refererHeader: 'https://www.pixivision.net/zh/',
      },
    ));
    d.httpClientAdapter = ConversionLayerAdapter(client);
    return d;
  }

  @action
  fetch(String url) async {
    // 防止下拉刷新与手动重试并发：二次触发会清掉首次刚解析出的结果
    if (isLoading) return;
    errorMessage = null;
    amWorks.clear();
    amArticles.clear();
    articleBlocks.clear();
    articleTitle = null;
    articleCategory = null;
    articleDate = null;
    description = null;
    isLoading = true;
    _log('fetch start, url=$url');

    try {
      dio = await _createDio();
      _log('Dio created, sending request...');
      await _doFetch(url);
    } on DioException catch (e) {
      errorMessage = '网络错误：${e.type.name}';
      _log('DioException: ${e.type.name} status=${e.response?.statusCode} msg=${e.message}');
    } catch (e, st) {
      errorMessage = '异常：$e';
      _log('error: $e\n$st');
    } finally {
      isLoading = false;
    }

    if (amWorks.isEmpty &&
        amArticles.isEmpty &&
        articleBlocks.isEmpty &&
        errorMessage == null) {
      errorMessage = '未提取到可展示内容（作品/卡片/正文均为空）';
      _log('amWorks/amArticles/articleBlocks STILL empty after doFetch');
    }
    _log('fetch done, works=${amWorks.length}, cards=${amArticles.length}, '
        'blocks=${articleBlocks.length}, error=$errorMessage');
  }

  Future<void> _doFetch(String url) async {
    final response = await dio.get(url);
    _log('HTTP ${response.statusCode}');

    final body = response.data is String
        ? response.data as String
        : response.data.toString();
    _log('body length=${body.length}');
    _log('body[0..400]=${body.substring(0, body.length < 400 ? body.length : 400)}');

    // 检查是否被 Cloudflare 拦截
    if (body.contains('cf-browser-verify') ||
        body.contains('_cf_chl_opt') ||
        body.contains('challenge-platform')) {
      errorMessage = '被 Cloudflare 拦截';
      _log('Cloudflare challenge detected!');
      return;
    }

    // 检查 403/421 等
    if (response.statusCode == 403 || response.statusCode == 421) {
      errorMessage = 'HTTP ${response.statusCode}';
      _log('blocked with ${response.statusCode}');
      return;
    }

    if (body.length < 500) {
      errorMessage = '响应内容过短（${body.length}字节）';
      _log('response too short: $body');
      return;
    }

    _parseHtmlBody(body);
  }

  // ---------------------------------------------------------------------
  // HTML 解析(与网络解耦,测试可注入真实 HTML)
  // ---------------------------------------------------------------------

  void _parseHtmlBody(String body) {
    var document = parse(body);
    _log('HTML parsed');

    // 提取特辑描述（meta description 优先，回退 article header 文本）
    final metaDesc = document.querySelector('meta[name="description"]');
    final metaContent = metaDesc?.attributes['content'];
    if (metaContent != null &&
        metaContent.isNotEmpty &&
        metaContent != 'pixivision') {
      description = metaContent;
    } else {
      final header = document.querySelector('article header');
      if (header != null) description = header.text.trim();
    }

    // 单篇文章正文页：pixivision 用 article.am__article-body-container
    // 包裹(2026-09 实测);合集/栏目列表页没有该容器
    final articleBody =
        document.querySelector('article.am__article-body-container');
    if (articleBody != null) {
      _parseArticleBody(articleBody);
      return;
    }
    _parseCollectionOrLegacy(document);
  }

  /// 单篇文章正文页解析：视觉特辑走作品流模式(与旧 UI 一致);
  /// 含问答/大段文字的专访、专栏等走文章块模式(articleBlocks)
  void _parseArticleBody(Element articleBody) {
    // 文章头部元信息(分类/日期/标题)
    final header = articleBody.querySelector('header.am__header');
    final titleEl = header?.querySelector('h1.am__title');
    final catEl = header?.querySelector('.am__categoty-pr');
    final dateEl = header?.querySelector('time');
    articleTitle =
        titleEl?.text.trim().isNotEmpty == true ? titleEl!.text.trim() : null;
    articleCategory =
        catEl?.text.trim().isNotEmpty == true ? catEl!.text.trim() : null;
    articleDate =
        dateEl?.text.trim().isNotEmpty == true ? dateEl!.text.trim() : null;
    _log('article header: title=$articleTitle cat=$articleCategory date=$articleDate');

    // 作品与正文块统计,决定渲染模式
    final works1 = articleBody.querySelectorAll('.am__work');
    final items = articleBody.querySelectorAll('.article-item');
    _log('article body: .am__work=${works1.length}, .article-item=${items.length}');

    // 文字型块(段落/来信/问答)计数：视觉特辑通常只有 0~1 个导语段
    int textyCount = 0;
    for (var item in items) {
      final c = item.attributes['class'] ?? '';
      if (c.contains('__paragraph') ||
          c.contains('__question') ||
          c.contains('__answer') ||
          c.contains('__link')) {
        textyCount++;
      }
    }

    // 视觉特辑(作品为主) → 保持既有作品流 UI
    if (works1.isNotEmpty && textyCount <= 1) {
      _log('visual article (works=${works1.length}, texty=$textyCount) -> works mode');
      for (var work in works1) {
        _parseAmWork(work);
      }
      return;
    }

    // 专访/专栏/图文混排 → 文章块模式
    for (var item in items) {
      final blocks = _parseArticleItem(item);
      for (final block in blocks) {
        articleBlocks.add(block);
      }
    }
    if (articleBlocks.isNotEmpty) {
      _log('article mode: parsed ${articleBlocks.length} blocks');
      return;
    }

    // 无作品也解析不出块：兼容旧布局兜底尝试,再失败则报错
    if (works1.isNotEmpty) {
      _log('fallback to works mode after empty blocks');
      for (var work in works1) {
        _parseAmWork(work);
      }
      return;
    }
    errorMessage = '未能解析文章正文结构（article-item 为空）';
    _log('article body parse failed: no works, no blocks');
  }

  /// 将一个 .article-item 正文块转为模型列表(单块可能含多个作品);
  /// 不支持的块类型返回空列表
  List<AmArticleBlock> _parseArticleItem(Element item) {
    final c = item.attributes['class'] ?? '';
    if (c.contains('__paragraph') ||
        c.contains('__question') ||
        c.contains('__link') ||
        c.contains('__answer') ||
        c.contains('__heading') ||
        c.contains('__credit') ||
        c.contains('__caption')) {
      // 文本类块统一富文本解析(<b> 加粗 / <a> 链接白名单)
      AmArticleBlockType type;
      Element? scope;
      if (c.contains('__question') || c.contains('__link')) {
        // 来信/提问(咨询来信 comment-content 语义等同 question)
        type = AmArticleBlockType.question;
      } else if (c.contains('__answer')) {
        type = AmArticleBlockType.answer;
        // 回答正文在 .answer-text(块内前半是作答者头像图)
        scope = item.querySelector('.answer-text');
      } else if (c.contains('__heading')) {
        type = AmArticleBlockType.heading;
      } else if (c.contains('__credit')) {
        type = AmArticleBlockType.credit;
      } else if (c.contains('__caption')) {
        type = AmArticleBlockType.caption;
      } else {
        type = AmArticleBlockType.paragraph;
      }
      final rich = _richSpans(scope ?? item);
      return [
        AmArticleBlock(
          type: type,
          text: _spansPlainText(rich),
          spans: rich,
        ),
      ];
    }
    if (c.contains('__image')) {
      final img = item.querySelector('img');
      final src = img?.attributes['src'] ?? '';
      if (src.isEmpty) return const [];
      return [
        AmArticleBlock(type: AmArticleBlockType.image, imageUrl: src),
      ];
    }
    if (c.contains('__pixiv_illust')) {
      // 一个块内含 1..n 个 .am__work(实测多为 1),每个作品一个块
      final works = item.querySelectorAll('.am__work');
      final blocks = <AmArticleBlock>[];
      for (final work in works) {
        final block = _workBlock(work);
        if (block != null) blocks.add(block);
      }
      return blocks;
    }
    if (c.contains('__article_card')) {
      // 文末相关特辑卡(._article-card),构造为可点开的卡片块
      final card = item.querySelector('._article-card') ?? item;
      final data = _readCard(card);
      if (data == null) return const [];
      return [
        AmArticleBlock(
          type: AmArticleBlockType.articleCard,
          text: data.title,
          imageUrl: data.thumbnail,
          linkUrl: data.articleUrl,
        ),
      ];
    }
    // 其他(profile/movie/table_of_contents/article_thumbnail 等)暂不渲染
    return const [];
  }

  AmArticleBlock? _workBlock(Element work) {
    final parsed = _parseWorkElement(work);
    if (parsed == null) return null;
    return AmArticleBlock(
      type: AmArticleBlockType.pixivIllust,
      text: parsed.title ?? '',
      imageUrl: parsed.showImage ?? '',
      linkUrl: parsed.arworkLink ?? '',
      work: parsed,
    );
  }

  /// 合集/栏目列表页(或旧版布局):优先解析全部卡片
  /// (._article-card + 首页头条 ._article-eyecatch-card,按文档序),
  /// 无卡片时回退旧逻辑(作品元素扫描)
  void _parseCollectionOrLegacy(Document document) {
    // 方法1: 桌面版 .am__work
    final works1 = document.querySelectorAll('.am__work');
    _log('.am__work (desktop) = ${works1.length}');

    // 方法2: 手机版 ._article-illust-work
    final worksSp = document.querySelectorAll('._article-illust-work');
    _log('._article-illust-work (mobile) = ${worksSp.length}');

    // 方法3: getElementsByClassName 桌面版
    final works2 = document.getElementsByClassName('am__work');
    _log('.am__work via class = ${works2.length}');

    // 直接搜索所有 div 的 class
    final allDivs = document.getElementsByTagName('div');
    int workCount = 0;
    for (var d in allDivs) {
      if ((d.attributes['class'] ?? '').contains('am__work')) workCount++;
    }
    _log('.am__work via manual scan = $workCount');

    // 卡片(单篇特辑入口):普通卡 + 首页头条卡,一律放行
    final cards =
        document.querySelectorAll('._article-card, ._article-eyecatch-card');
    _log('article cards found: ${cards.length} '
        '(eyecatch=${document.querySelectorAll('._article-eyecatch-card').length})');
    if (cards.isNotEmpty) {
      for (var card in cards) {
        _parseArticleCard(card);
      }
      if (amArticles.isEmpty) {
        errorMessage = '卡片解析失败（卡片存在但未提取到链接）';
        _log('cards exist but none parsed');
      }
      return;
    }

    // 使用找到的元素（优先桌面版，回退手机版）
    var workElements = works1.isNotEmpty ? works1 : works2;
    final isMobile = workElements.isEmpty && worksSp.isNotEmpty;

    if (isMobile) {
      workElements = worksSp;
      _log('using mobile layout');
      for (var work in worksSp) {
        _parseMobileWork(work);
      }
    } else if (workElements.isEmpty && workCount == 0) {
      // 既无卡片也无作品:兜底输出日志帮助定位
      final articles = document.getElementsByTagName('article');
      _log('articles found: ${articles.length}');
      if (articles.isNotEmpty) {
        final art = articles.first;
        _log('article outerHtml[0..800]=${art.outerHtml.substring(0, art.outerHtml.length < 800 ? art.outerHtml.length : 800)}');
      }
      errorMessage = '未找到作品元素或卡片（class 列表见日志）';
      return;
    } else {
      for (var work in workElements) {
        _parseAmWork(work);
      }
    }
    _log('parsed ${amWorks.length} works');
  }

  /// 解析手机版 ._article-illust-work 元素
  void _parseMobileWork(Element work) {
    AmWork amWork = AmWork();
    final links = work.getElementsByTagName('a');
    final imgs = work.getElementsByTagName('img');

    for (var aa in links) {
      final href = aa.attributes['href'];
      if (href == null) continue;

      if (href.contains('artworks')) {
        amWork.arworkLink = href;
        // 作品图在 amsp__work__main > img
        for (var img in imgs) {
          final src = img.attributes['src'] ?? '';
          if (src.contains('pximg.net') && !src.contains('user-profile')) {
            amWork.showImage = src;
            break;
          }
        }
        // 标题
        final h3s = work.getElementsByTagName('h3');
        if (h3s.isNotEmpty) amWork.title = h3s.first.text.trim();
        if (amWork.title == null || amWork.title!.isEmpty) {
          amWork.title = aa.text.trim();
        }
      } else if (href.contains('users')) {
        amWork.userLink = href;
        // 头像
        for (var img in imgs) {
          final src = img.attributes['src'] ?? '';
          if (src.contains('user-profile')) {
            amWork.userImage = src;
            break;
          }
        }
        // 作者
        final namePs = work.getElementsByTagName('p');
        if (namePs.isNotEmpty) amWork.user = namePs.first.text.trim();
      }
    }

    amWork.userImage ??= imgs.isNotEmpty ? imgs.first.attributes['src'] : null;

    if (amWork.userLink != null && amWork.arworkLink != null) {
      amWorks.add(amWork);
      _log('added mobile work "${amWork.title}"');
    }
  }

  /// 解析单个 .am__work 作品元素为模型(不加入 amWorks)
  AmWork? _parseWorkElement(Element work) {
    AmWork amWork = AmWork();
    final links = work.getElementsByTagName('a');
    final imgs = work.getElementsByTagName('img');

    for (var aa in links) {
      final href = aa.attributes['href'];
      if (href == null) continue;

      if (href.contains('artworks')) {
        amWork.arworkLink ??= href;
        // 作品图: img.am__work__illust
        for (var img in imgs) {
          final ic = img.attributes['class'] ?? '';
          if (ic.contains('am__work__illust')) {
            amWork.showImage = img.attributes['src'];
            break;
          }
        }
        // 标题: h3
        final h3s = work.getElementsByTagName('h3');
        if (h3s.isNotEmpty) amWork.title = h3s.first.text.trim();
        if (amWork.title == null || amWork.title!.isEmpty) {
          amWork.title = aa.text.trim();
        }
      } else if (href.contains('users')) {
        amWork.userLink ??= href;
        // 头像: img.am__work__uesr-icon
        for (var img in imgs) {
          final ic = img.attributes['class'] ?? '';
          if (ic.contains('uesr-icon')) {
            amWork.userImage = img.attributes['src'];
            break;
          }
        }
        // 作者: p.am__work__user-name
        final namePs = work.getElementsByClassName('am__work__user-name');
        if (namePs.isNotEmpty) {
          amWork.user = namePs.first.text.replaceAll('by ', '').trim();
        }
      }
    }

    // 回退补全
    amWork.userImage ??= imgs.isNotEmpty ? imgs.first.attributes['src'] : null;
    if (amWork.user == null) {
      final ps = work.getElementsByTagName('p');
      if (ps.isNotEmpty) amWork.user = ps.first.text.trim();
    }

    if (amWork.userLink != null && amWork.arworkLink != null) {
      return amWork;
    }
    return null;
  }

  /// 解析桌面版 .am__work 元素(作品流模式)
  void _parseAmWork(Element work) {
    final amWork = _parseWorkElement(work);
    if (amWork == null) {
      _log('work parse skipped (missing link)');
      return;
    }
    amWorks.add(amWork);
    _log('added work "${amWork.title}" by ${amWork.user}');
  }

  /// 解析正文富文本为有序行内片段(白名单: <b>/<strong> 加粗、<a> 链接;
  /// 其余标签只透传文本)。段落(p/li/标题)之间插入空行,<br> 单换行。
  List<AmInlineSpan> _richSpans(Element container) {
    // 排版块级(p/标题/li/blockquote);div 等容器不算(避免嵌套重复空行)
    const blockTags = {
      'p', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote',
    };

    List<AmInlineSpan> walk(Node node, bool bold, String? link) {
      if (node is Text) {
        final t = node.data;
        return t.isEmpty ? const [] : [AmInlineSpan(text: t, bold: bold, link: link)];
      }
      if (node is! Element) return const [];
      final tag = node.localName;
      if (tag == 'br') {
        return const [AmInlineSpan(text: '\n')];
      }
      var childBold = bold;
      var childLink = link;
      if (tag == 'b' || tag == 'strong') childBold = true;
      if (tag == 'a') {
        final href = node.attributes['href'];
        if (href != null && href.isNotEmpty) childLink = href;
      }
      final sub = <AmInlineSpan>[];
      for (final c in node.nodes) {
        sub.addAll(walk(c, childBold, childLink));
      }
      if (blockTags.contains(tag)) {
        // 空段落(全空白)丢弃;否则段落尾部加空行(段间距)
        if (!sub.any((s) => s.text.trim().isNotEmpty)) return const [];
        return [...sub, const AmInlineSpan(text: '\n\n')];
      }
      return sub;
    }

    final raw = walk(container, false, null);
    // 归一:合并相邻同格式片段;压缩多余空行;去掉首尾空行
    final out = <AmInlineSpan>[];
    for (final s in raw) {
      final t = s.text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
      if (t.isEmpty) continue;
      final last = out.isEmpty ? null : out.last;
      if (last != null && last.bold == s.bold && last.link == s.link) {
        out[out.length - 1] = AmInlineSpan(
            text: last.text + t, bold: last.bold, link: last.link);
      } else {
        out.add(AmInlineSpan(text: t, bold: s.bold, link: s.link));
      }
    }
    while (out.isNotEmpty && out.first.text.trim().isEmpty) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && out.last.text.trim().isEmpty) {
      out.removeLast();
    }
    return out;
  }

  /// 富文本片段拼接为纯文本(压缩空白,段落以空行分隔)
  String _spansPlainText(List<AmInlineSpan> spans) {
    return spans
        .map((s) => s.text)
        .join()
        .replaceAll(RegExp(r'[ \t\r]+'), ' ')
        .trim();
  }

  /// 解析集合/文末卡片(兼容 ._article-card 与 ._article-eyecatch-card
  /// 两种前缀结构),返回卡片数据;无有效链接返回 null
  _CardData? _readCard(Element card) {
    // 分类:标签 span(arc/aec 前缀)优先,回退分类链接
    final catEl = card.querySelector('.arc__thumbnail-label') ??
        card.querySelector('.aec__thumbnail-label') ??
        card.querySelector('a[href*="/c/"]');
    final catName = catEl?.text.trim() ?? '';
    final catHref = catEl?.attributes['href'] ?? '';

    // 标题与文章链接(arc/aec 两种卡片)
    final titleEl = card.querySelector('.arc__title a') ??
        card.querySelector('.aec__title a');
    final title = titleEl?.text.trim() ?? '';
    var href = titleEl?.attributes['href'] ?? '';
    if (href.isEmpty) {
      final aEl = card.querySelector('a[href*="/a/"]');
      href = aEl?.attributes['href'] ?? '';
    }
    if (href.isEmpty) return null;

    final fullUrl =
        href.startsWith('http') ? href : 'https://www.pixivision.net$href';

    // 封面缩略图(style 背景图优先,回退 <img>)
    String thumbnail = '';
    final thumbDiv = card.querySelector('._thumbnail');
    final style = thumbDiv?.attributes['style'] ?? '';
    final urlMatch = RegExp(r'url\((.*?)\)').firstMatch(style);
    if (urlMatch != null) {
      thumbnail =
          urlMatch.group(1)!.replaceAll("'", '').replaceAll('"', '').trim();
    }
    if (thumbnail.isEmpty) {
      final img = card.querySelector('img');
      thumbnail = img?.attributes['src'] ?? '';
    }

    // 日期
    final dateEl =
        card.querySelector('time._date') ?? card.querySelector('time');
    final date = dateEl?.text.trim() ?? '';

    return _CardData(
      title: title,
      articleUrl: fullUrl,
      thumbnail: thumbnail,
      category: catName.isNotEmpty ? catName : (catHref.isNotEmpty ? catHref.split('/c/').last : ''),
      date: date,
    );
  }

  /// 合集/栏目列表页卡片解析(全部类型放行:特辑/专访/专栏/趣闻等)
  void _parseArticleCard(Element card) {
    final data = _readCard(card);
    if (data == null) {
      _log('skipped article card (no link): "${card.text.trim().substring(0, card.text.trim().length < 60 ? card.text.trim().length : 60)}"');
      return;
    }
    amArticles.add(AmArticleCard(
      id: data.idFromUrl,
      title: data.title,
      articleUrl: data.articleUrl,
      thumbnail: data.thumbnail,
      category: data.category,
      date: data.date,
    ));
    _log('added article card: "${data.title}"');
  }

  /// 测试入口:与 fetch() 相同语义——先清空上一页状态再解析
  @visibleForTesting
  void testParseHtml(String html) {
    errorMessage = null;
    amWorks.clear();
    amArticles.clear();
    articleBlocks.clear();
    articleTitle = null;
    articleCategory = null;
    articleDate = null;
    description = null;
    _parseHtmlBody(html);
  }

  @visibleForTesting
  void testParseArticleCard(Element card) => _parseArticleCard(card);
}

/// 卡片解析中间数据(集合卡与文章块共用)
class _CardData {
  final String title;
  final String articleUrl;
  final String thumbnail;
  final String category;
  final String date;

  _CardData({
    required this.title,
    required this.articleUrl,
    required this.thumbnail,
    required this.category,
    required this.date,
  });

  /// 从文章 URL 提取 id(/zh/a/12345 → 12345),失败返回空串
  String get idFromUrl {
    final m = RegExp(r'/a/(\d+)').firstMatch(articleUrl);
    return m?.group(1) ?? '';
  }
}
