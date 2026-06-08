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
import 'package:dio/dio.dart';
import 'package:mobx/mobx.dart';
import 'package:html/parser.dart' show parse;
import 'package:pixez/main.dart';
import 'package:pixez/models/amwork.dart';
import 'package:rhttp/rhttp.dart' as r;
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:html/dom.dart';

part 'soup_store.g.dart';

class SoupStore = _SoupStoreBase with _$SoupStore;

abstract class _SoupStoreBase with Store {
  @observable
  late Dio dio;

  ObservableList<AmWork> amWorks = ObservableList();

  @observable
  String? description;

  @observable
  String? errorMessage;

  @observable
  String logText = '';

  void _log(String msg) {
    print('SoupStore: $msg');
    logText += '$msg\n';
  }

  // 已验证可访问 pixivision 的 Pixiv 源站 IP
  static const _visionIps = [
    '210.140.139.154',
    '210.140.139.155',
    '210.140.139.156',
    '210.140.139.157',
    '210.140.139.158',
    '210.140.139.159',
  ];

  Future<Dio> _createDio() async {
    _log('creating rhttp client...');
    final client = await r.RhttpCompatibleClient.create(
      settings: r.ClientSettings(
        tlsSettings: r.TlsSettings(verifyCertificates: false, sni: false),
        dnsSettings: r.DnsSettings.static(
          overrides: {
            'www.pixivision.net': _visionIps,
          },
        ),
      ),
    );
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
    errorMessage = null;
    amWorks.clear();
    description = null;
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
    }

    if (amWorks.isEmpty && errorMessage == null) {
      errorMessage = '未提取到作品（amWorks 为空）';
      _log('amWorks STILL empty after doFetch');
    }
    _log('fetch done, amWorks=${amWorks.length}, error=$errorMessage');
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
}

extension ElementExt on Element {
  String toTargetString() {
    return this
        .getElementsByTagName('p')
        .map((e) => e.text)
        .toList()
        .toString()
        .replaceAll('[', '')
        .replaceAll(']', '')
        .replaceAll(',', '');
  }
}
