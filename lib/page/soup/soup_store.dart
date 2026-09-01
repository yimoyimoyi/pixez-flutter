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
import 'package:pixez/models/am_article_card.dart';
import 'package:pixez/models/amwork.dart';
import 'package:rhttp/rhttp.dart' as r;
import 'package:html/dom.dart';

part 'soup_store.g.dart';

class SoupStore = _SoupStoreBase with _$SoupStore;

abstract class _SoupStoreBase with Store {
  @observable
  late Dio dio;

  ObservableList<AmWork> amWorks = ObservableList();
  ObservableList<AmArticleCard> amArticles = ObservableList();

  @observable
  bool isTextArticle = false;

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
    isTextArticle = false;
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

    if (amWorks.isEmpty && amArticles.isEmpty && errorMessage == null) {
      if (isTextArticle) {
        errorMessage = '本文为文字专栏特辑，不包含插画作品';
      } else {
        errorMessage = '未提取到作品（amWorks 与 amArticles 均为空）';
      }
      _log('amWorks and amArticles STILL empty after doFetch');
    }
    _log('fetch done, amWorks=${amWorks.length}, amArticles=${amArticles.length}, error=$errorMessage');
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

    // HTML 解析
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

    // 方法1: 桌面版 .am__work
    final works1 = document.querySelectorAll('.am__work');
    _log('.am__work (desktop) = ${works1.length}');

    // 方法2: 手机版 ._article-illust-work
    final worksSp = document.querySelectorAll('._article-illust-work');
    _log('._article-illust-work (mobile) = ${worksSp.length}');

    // 方法3: getElementsByClassName 桌面版
    final works2 = document.getElementsByClassName('am__work');
    _log('.am__work via class = ${works2.length}');

    // 方法3: 直接搜索所有 div 的 class
    final allDivs = document.getElementsByTagName('div');
    int workCount = 0;
    for (var d in allDivs) {
      if ((d.attributes['class'] ?? '').contains('am__work')) workCount++;
    }
    _log('.am__work via manual scan = $workCount');

    // 方法4: 列出所有含 "work" 或 "illust" 的 class
    final relevantClasses = <String>{};
    for (var d in allDivs) {
      final c = d.attributes['class'] ?? '';
      if (c.contains('work') || c.contains('illust') || c.contains('am_')) {
        relevantClasses.add(c);
      }
    }
    _log('relevant classes: $relevantClasses');

    // 使用找到的元素（优先桌面版，回退手机版）
    var workElements = works1.isNotEmpty ? works1 : works2;
    final isMobile = workElements.isEmpty && worksSp.isNotEmpty;

    if (isMobile) {
      workElements = worksSp;
      _log('using mobile layout');
      // 手机版用不同的解析方式
      for (var work in worksSp) {
        _parseMobileWork(work);
      }
    } else if (workElements.isEmpty && workCount == 0) {
      // 检查是否为特辑合集页面（正文包含多个 _article-card 特辑推荐卡片）
      final bodyContainer =
          document.querySelector('article.am__article-body-container') ??
              document.querySelector('.am__body') ??
              document.querySelector('._feature-article-body') ??
              document.body;

      final cards = bodyContainer?.querySelectorAll('._article-card') ?? [];
      _log('collection article cards found: ${cards.length}');

      if (cards.isNotEmpty) {
        for (var card in cards) {
          _parseArticleCard(card);
        }
      }

      if (amArticles.isNotEmpty) {
        _log('parsed ${amArticles.length} collection articles (text articles filtered)');
        return;
      }

      // 如果卡片全被过滤掉，或者根本没有卡片，检查是否是文字专栏特辑
      final pageCategory =
          document.querySelector('.am__categoty-pr')?.text.trim() ?? '';
      final pageHeading =
          document.querySelector('h1.am__title')?.text.trim() ?? '';
      if (_isTextCategory(pageCategory) ||
          url.contains('/c/column') ||
          url.contains('/c/news') ||
          pageHeading.contains('的咨询') ||
          pageHeading.contains('の相談') ||
          (cards.isNotEmpty && amArticles.isEmpty)) {
        isTextArticle = true;
        errorMessage = '本文为文字专栏特辑，不包含插画作品';
        _log('detected text-only column article');
        return;
      }

      final articles = document.getElementsByTagName('article');
      _log('articles found: ${articles.length}');
      if (articles.isNotEmpty) {
        final art = articles.first;
        _log('article outerHtml[0..800]=${art.outerHtml.substring(0, art.outerHtml.length < 800 ? art.outerHtml.length : 800)}');
      }
      errorMessage = '未找到作品元素（class 列表见日志）';
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

  /// 解析桌面版 .am__work 元素
  void _parseAmWork(Element work) {
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
      amWorks.add(amWork);
      _log('added work "${amWork.title}" by ${amWork.user}');
    }
  }

  /// 判断是否为文字类特辑分类（专栏、新闻、小说等）
  bool _isTextCategory(String text) {
    final lower = text.toLowerCase();
    return lower.contains('column') ||
        lower.contains('专栏') ||
        lower.contains('コラム') ||
        lower.contains('news') ||
        lower.contains('新闻') ||
        lower.contains('ニュース') ||
        lower.contains('novel') ||
        lower.contains('小说') ||
        lower.contains('小説') ||
        lower.contains('inspiration');
  }

  /// 解析特辑合集中的 ._article-card 元素，直接过滤掉文字特辑
  void _parseArticleCard(Element card) {
    final cardClasses = card.attributes['class'] ?? '';

    // 1. 分类信息
    final catEl = card.querySelector('.arc__thumbnail-label') ??
        card.querySelector('a[href*="/c/"]');
    final catName = catEl?.text.trim() ?? '';
    final catHref = catEl?.attributes['href'] ?? '';

    // 2. 标题和链接
    final titleEl = card.querySelector('.arc__title a');
    final title = titleEl?.text.trim() ?? '';
    var href = titleEl?.attributes['href'] ?? '';
    if (href.isEmpty) {
      final aEl = card.querySelector('a[href*="/a/"]');
      href = aEl?.attributes['href'] ?? '';
    }
    if (href.isEmpty) return;

    // 过滤文字特辑：专栏、新闻、小说、灵感等
    if (_isTextCategory(cardClasses) ||
        _isTextCategory(catName) ||
        _isTextCategory(catHref) ||
        title.contains('的咨询') ||
        title.contains('の相談')) {
      _log('filtered text article card: "$title" [$catName]');
      return;
    }

    final fullUrl =
        href.startsWith('http') ? href : 'https://www.pixivision.net$href';
    final idMatch = RegExp(r'/a/(\d+)').firstMatch(href);
    final id = idMatch?.group(1) ?? '';

    // 3. 封面缩略图
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

    // 4. 日期
    final dateEl =
        card.querySelector('time._date') ?? card.querySelector('time');
    final date = dateEl?.text.trim() ?? '';

    amArticles.add(AmArticleCard(
      id: id,
      title: title,
      articleUrl: fullUrl,
      thumbnail: thumbnail,
      category: catName.isNotEmpty ? catName : '插画',
      date: date,
    ));
    _log('added collection article card: "$title"');
  }

  @visibleForTesting
  bool testIsTextCategory(String text) => _isTextCategory(text);

  @visibleForTesting
  void testParseArticleCard(Element card) => _parseArticleCard(card);
}

