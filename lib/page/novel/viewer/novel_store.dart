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

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart';
import 'package:mobx/mobx.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/novel_viewer_persist.dart';
import 'package:pixez/models/novel_web_response.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart';

part 'novel_store.g.dart';

class NovelStore = _NovelStoreBase with _$NovelStore;

abstract class _NovelStoreBase with Store {
  final int id;

  _NovelStoreBase(this.id, this.novel);

  @observable
  Novel? novel;
  @observable
  NovelWebResponse? novelTextResponse;
  @observable
  String? errorMessage;
  @observable
  bool positionBooked = false;

  @observable
  double bookedOffset = 0.0;
  @observable
  List<NovelSpansData> spans = [];

  NovelViewerPersistProvider _novelViewerPersistProvider =
      NovelViewerPersistProvider();

  @action
  bookPosition(double offset) async {
    LPrinter.d("bookPosition $offset");
    await _novelViewerPersistProvider.open();
    await _novelViewerPersistProvider
        .insert(NovelViewerPersist(novelId: id, offset: offset));
    positionBooked = true;
  }

  @action
  deleteBookPosition() async {
    LPrinter.d("deleteBookPosition");
    await _novelViewerPersistProvider.open();
    await _novelViewerPersistProvider.delete(id);
    positionBooked = false;
  }

  @action
  Future<void> fetch() async {
    errorMessage = null;
    try {
      bookedOffset = 0.0;
      // 1) 先取元数据（轻量 API，高成功率）
      if (novel == null) {
        try {
          final detailResp = await apiClient.getNovelDetail(id);
          novel = Novel.fromJson(detailResp.data['novel']);
          novelHistoryStore.insert(novel!);
        } catch (metaErr) {
          print('novel metadata fetch failed: $metaErr');
          // 失败时尝试从本地历史恢复元数据（方案 C）
          if (novel == null) {
            novel = await _restoreNovelFromHistory();
          }
        }
      }
      // 2) 再取正文（HTML 解析，可能失败）
      final response = await apiClient.webviewNovel(id);
      final html = response.data is String ? response.data : response.data.toString();
      String? json = _parseHtml(html);
      if (json == null) {
        // 尝试从缓存加载（方案 A）
        if (await _loadNovelTextFromCache()) return;
        errorMessage = '页面结构异常，无法解析小说正文';
        return;
      }
      novelTextResponse = NovelWebResponse.fromJson(jsonDecode(json));
      spans = await compute(buildSpans, novelTextResponse!);
      if (novel != null) novelHistoryStore.insert(novel!);
      // 正文加载成功后保存到本地缓存（方案 A）
      await _saveNovelTextToCache(json);
      fetchOffset();
    } on DioException catch (e) {
      print(e);
      if (e.response?.statusCode == 404) {
        // 作品已删除/下架（方案 C）
        await _handleDeletedNovel();
        return;
      }
      // 尝试从缓存加载（方案 A）
      if (await _loadNovelTextFromCache()) return;
      errorMessage = '加载失败：${e.toString().split('\n').first}'
          '${novel != null ? '\n已保留作品信息，可重试' : ''}';
    } catch (e) {
      print(e);
      // 尝试从缓存加载（方案 A）
      if (await _loadNovelTextFromCache()) return;
      errorMessage = '加载失败：${e.toString().split('\n').first}'
          '${novel != null ? '\n已保留作品信息，可重试' : ''}';
    }
  }

  /// 获取小说正文缓存文件路径
  Future<File> _novelTextCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/novel_text_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/novel_$id.json');
  }

  /// 保存小说正文 JSON 到本地文件
  Future<void> _saveNovelTextToCache(String json) async {
    try {
      final file = await _novelTextCacheFile();
      await file.writeAsString(json);
      // 同时保存元数据用于离线恢复
      if (novel != null) {
        final metaFile = File('${file.path}.meta');
        await metaFile.writeAsString(jsonEncode({
          'title': novel!.title,
          'userName': novel!.user.name,
          'userId': novel!.user.id,
          'coverUrl': novel!.imageUrls.medium,
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
        }));
      }
    } catch (e) {
      print('_saveNovelTextToCache error: $e');
    }
  }

  /// 从本地缓存加载小说正文
  Future<bool> _loadNovelTextFromCache() async {
    try {
      final file = await _novelTextCacheFile();
      if (!await file.exists()) return false;
      final json = await file.readAsString();
      novelTextResponse = NovelWebResponse.fromJson(jsonDecode(json));
      spans = await compute(buildSpans, novelTextResponse!);
      errorMessage = null; // 清除错误状态
      fetchOffset();
      return true;
    } catch (e) {
      print('_loadNovelTextFromCache error: $e');
      return false;
    }
  }

  /// 从历史记录恢复小说元数据（方案 C）
  Future<Novel?> _restoreNovelFromHistory() async {
    try {
      await novelHistoryStore.novelPersistProvider.open();
      final all = await novelHistoryStore.novelPersistProvider.getAllAccount();
      final match = all.where((p) => p.novelId == id).toList();
      if (match.isNotEmpty) {
        final p = match.first;
        return Novel.fromJson({
          'id': p.novelId.toString(),
          'title': p.title,
          'user': {'id': p.userId.toString(), 'name': p.userName},
          'image_urls': {'square_medium': p.pictureUrl, 'medium': p.pictureUrl, 'large': p.pictureUrl},
          'total_bookmarks': 0, 'total_view': 0,
          'create_date': '',
        });
      }
    } catch (e) {
      print('_restoreNovelFromHistory error: $e');
    }
    return null;
  }

  /// 处理已删除的小说（方案 C）
  Future<void> _handleDeletedNovel() async {
    // 先从缓存加载正文
    final hasCache = await _loadNovelTextFromCache();
    // 从历史恢复元数据
    if (novel == null) {
      novel = await _restoreNovelFromHistory();
    }
    if (hasCache) return;
    if (novel != null) {
      errorMessage = '作品已失效（缓存信息）';
    } else {
      errorMessage = '作品已失效（404 Not Found）';
    }
  }

  String? _parseHtml(String html) {
    var document = parse(html);
    final scriptElement = document.querySelector('script');
    if (scriptElement == null) {
      print('novel _parseHtml: no <script> found');
      return null;
    }
    String scriptContent = scriptElement.innerHtml;
    // 尝试多种正则匹配（Pixiv 页面结构可能变化）
    for (final regex in [
      RegExp(r'novel: ({.*?}),\n\s*isOwnWork'),
      RegExp(r'novel: ({.*?})'),  // fallback
    ]) {
      final match = regex.firstMatch(scriptContent);
      if (match != null) {
        final json = match.group(1);
        if (json != null && json.isNotEmpty) return json;
      }
    }
    return null;
  }

  @action
  fetchOffset() async {
    try {
      await _novelViewerPersistProvider.open();
      final result = await _novelViewerPersistProvider.getNovelPersistById(id);
      if (result != null) {
        LPrinter.d("fetchOffset ${result.offset}");
        positionBooked = true;
        bookedOffset = result.offset;
      }
    } catch (e) {}
  }
}

class ComputeSpan {
  final BuildContext context;
  final NovelWebResponse webResponse;

  ComputeSpan(this.context, this.webResponse);
}

Future<List<NovelSpansData>> buildSpans(NovelWebResponse webResponse) {
  final generator = NovelSpansGenerator();
  return Future.value(generator.buildSpans(webResponse));
}
