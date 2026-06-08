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
import 'package:pixez/network/api_client.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:rhttp/rhttp.dart' as r;
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:html/dom.dart';

part 'soup_store.g.dart';

class SoupStore = _SoupStoreBase with _$SoupStore;

abstract class _SoupStoreBase with Store {
  // 使用 compat 模式（sni:false + 源站 IP 池），直连 Pixiv 源站绕过 Cloudflare
  @observable
  late Dio dio;

  Future<Dio> _createDio() async {
    // 使用 compat 模式直连 Pixiv 源站 IP，绕过 Cloudflare
    // www.pixivision.net 与 app-api.pixiv.net 共享同一批源站服务器
    print('SoupStore: creating compat client...');
    final client = await r.RhttpCompatibleClient.createSync(
      settings: PixezNetworkSettings.compatible(),
    );
    print('SoupStore: compat client created, creating Dio...');
    final d = Dio(BaseOptions(headers: {
      HttpHeaders.acceptLanguageHeader:
          userSetting.languageNum < 5 ? ApiClient.Accept_Language : "en-US",
      'user-agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1',
      HttpHeaders.refererHeader: 'https://www.pixivision.net/zh/',
    }));
    d.httpClientAdapter = ConversionLayerAdapter(client);
    return d;
  }

  ObservableList<AmWork> amWorks = ObservableList();

  @observable
  String? description;

  @observable
  String? errorMessage;

  @action
  fetch(String url) async {
    try {
      errorMessage = null;
      amWorks.clear();
      description = null;
      dio = await _createDio();
      if (userSetting.languageNum == 0 || userSetting.languageNum >= 5) {
        await _fetchEn(url);
      } else {
        await _fetchCNTW(url);
      }
      // 请求和解析都成功但没提取到内容
      if (amWorks.isEmpty && errorMessage == null) {
        errorMessage = '文章结构解析失败，可能页面已更新';
        print('SoupStore: amWorks empty after successful fetch');
      }
    } on DioException catch (e) {
      errorMessage = e.response?.statusCode == 404
          ? '404 NOT FOUND'
          : '网络错误：${e.type.name}';
      print('SoupStore DioException: ${e.type.name} ${e.message}');
    } catch (e) {
      errorMessage = '异常：$e';
      print('SoupStore error: $e');
    }
  }

  _fetchEn(url) async {
    Response response = await dio.request(url);
    print('SoupStore _fetchEn status: ${response.statusCode}');
    final body = response.data.toString();
    print('SoupStore body length: ${body.length}, preview: ${body.substring(0, body.length < 300 ? body.length : 300)}');
    var document = parse(body);
    amWorks.clear();
    description = '';

    final articles = document.getElementsByTagName('article');
    if (articles.isEmpty) {
      print('SoupStore: no <article> found');
      errorMessage = '页面结构异常，未找到文章内容';
      return;
    }
    final article = articles.first;

    final amBodyList = article.getElementsByClassName('am__body');
    if (amBodyList.isEmpty) {
      print('SoupStore: no .am__body found, classes on article children:');
      for (var c in article.children) {
        print('  child class: ${c.attributes["class"]}');
      }
      errorMessage = '文章结构已更新，请联系开发者';
      return;
    }

    var nodes = amBodyList.first.children;

    if (nodes.isNotEmpty && nodes.first.attributes['class']!.contains('_feature')) {
      nodes = nodes.first.children;
    } else {
      final headers = article.getElementsByTagName('header');
      if (headers.isNotEmpty) {
        description = headers.first.toTargetString();
      }
    }

    _parseIllustNodes(nodes);
  }

  _fetchCNTW(url) async {
    Response response = await dio.request(url);
    print('SoupStore _fetchCNTW status: ${response.statusCode}');
    final body = response.data.toString();
    print('SoupStore body length: ${body.length}, preview: ${body.substring(0, body.length < 300 ? body.length : 300)}');
    var document = parse(body);
    amWorks.clear();
    description = '';

    final articles = document.getElementsByTagName('article');
    if (articles.isEmpty) {
      print('SoupStore: no <article> found');
      errorMessage = '页面结构异常，未找到文章内容';
      return;
    }
    final article = articles.first;

    final amBodyList = article.getElementsByClassName('am__body');
    if (amBodyList.isEmpty) {
      print('SoupStore: no .am__body found, article children classes:');
      for (var c in article.children) {
        print('  ${c.attributes["class"]}');
      }
      errorMessage = '文章结构已更新，请联系开发者';
      return;
    }

    var nodes = amBodyList.first.children;

    if (nodes.isNotEmpty && nodes.first.attributes['class']!.contains('_feature')) {
      nodes = nodes.first.children;
    } else {
      final headers = article.getElementsByTagName('header');
      if (headers.isNotEmpty) {
        description = headers.first.toTargetString();
      }
    }

    _parseIllustNodes(nodes);
  }

  /// 从 DOM 节点列表中提取插画信息
  /// 支持两种结构：新版 .am__work 和旧版 .illust
  void _parseIllustNodes(List<Element> nodes) {
    // 新版结构：在 am__body 子节点中寻找 .am__work 或包含 .am__work 的节点
    for (var node in nodes) {
      try {
        // 新版：.article-item._feature-article-body__pixiv_illust > .am__work
        final workElements = node.getElementsByClassName('am__work');
        if (workElements.isNotEmpty) {
          for (var work in workElements) {
            _parseAmWork(work);
          }
          continue;
        }

        // 直接在子节点中找 .am__work
        final cls = node.attributes['class'] ?? '';
        if (cls.contains('am__work')) {
          _parseAmWork(node);
          continue;
        }

        // 旧版兼容：.illust 节点
        if (cls.contains('illust')) {
          _parseOldIllust(node);
        }
      } catch (e) {
        print('SoupStore parse node error: $e');
      }
    }
  }

  /// 解析新版 .am__work 元素
  void _parseAmWork(Element work) {
    AmWork amWork = AmWork();
    final links = work.getElementsByTagName('a');
    final imgs = work.getElementsByTagName('img');

    for (var aa in links) {
      final href = aa.attributes['href'];
      if (href == null) continue;

      if (href.contains('artworks')) {
        amWork.arworkLink ??= href;
        // 作品图在 am__work__main 中的 img.am__work__illust
        if (amWork.showImage == null) {
          for (var img in imgs) {
            final ic = img.attributes['class'] ?? '';
            if (ic.contains('am__work__illust')) {
              amWork.showImage = img.attributes['src'];
              break;
            }
          }
        }
        // 标题在 h3.am__work__title 中
        final h3s = work.getElementsByTagName('h3');
        if (h3s.isNotEmpty) amWork.title = h3s.first.text;
      } else if (href.contains('users')) {
        amWork.userLink ??= href;
        // 头像在 img.am__work__uesr-icon 中
        for (var img in imgs) {
          final ic = img.attributes['class'] ?? '';
          if (ic.contains('am__work__uesr-icon') || ic.contains('uesr-icon')) {
            amWork.userImage = img.attributes['src'];
            break;
          }
        }
        // 作者名在 p.am__work__user-name 中
        final namePs = work.getElementsByClassName('am__work__user-name');
        if (namePs.isNotEmpty) {
          amWork.user = namePs.first.text.replaceAll('by ', '');
        } else {
          final ps = work.getElementsByTagName('p');
          if (ps.isNotEmpty) amWork.user = ps.first.text;
        }
      }
    }

    // 如果标题没从 h3 拿到，从 artwork 链接文本获取
    if (amWork.title == null) {
      for (var aa in links) {
        final href = aa.attributes['href'] ?? '';
        if (href.contains('artworks')) {
          amWork.title = aa.text.trim();
          if (amWork.title!.isNotEmpty) break;
        }
      }
    }

    if (amWork.userLink != null && amWork.arworkLink != null) {
      // 如果没找到头像，尝试从第一个 img 获取
      amWork.userImage ??= imgs.isNotEmpty ? imgs.first.attributes['src'] : null;
      amWorks.add(amWork);
    }
  }

  /// 旧版 .illust 节点解析（兼容可能存在的旧格式）
  void _parseOldIllust(Element value) {
    AmWork amWork = AmWork();
    final links = value.getElementsByTagName('a');
    final imgs = value.getElementsByTagName('img');

    for (var aa in links) {
      var a = aa.attributes['href'];
      if (a == null) continue;

      if (a.contains('artworks')) {
        amWork.arworkLink = a;
        if (imgs.length > 1) {
          amWork.showImage = imgs[1].attributes['src'];
        }
        final h3s = value.getElementsByTagName('h3');
        if (h3s.isNotEmpty) amWork.title = h3s.first.text;
      } else if (a.contains('users')) {
        amWork.userLink = a;
        final ps = value.getElementsByTagName('p');
        if (ps.isNotEmpty) amWork.user = ps.first.text;
        if (imgs.isNotEmpty) {
          amWork.userImage = imgs.first.attributes['src'];
        }
      }
    }
    if (amWork.userLink != null && amWork.arworkLink != null) {
      amWorks.add(amWork);
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
