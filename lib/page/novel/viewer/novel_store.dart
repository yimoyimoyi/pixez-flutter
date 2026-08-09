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
    await _novelViewerPersistProvider.insert(
      NovelViewerPersist(novelId: id, offset: offset),
    );
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
      // 使用花括号配对解析（上游 parseNovelJsonFromHtml，鲁棒性优于正则）
      final json = parseNovelJsonFromHtml(html);
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
      // 元数据始终缺失（API 失败 + 历史恢复失败）时不能静默转圈：
      // 正文可显示但作品信息缺失，进入错误分支（带重试按钮）
      if (novel == null) {
        errorMessage = '正文已加载，但作品信息不可用，可重试刷新';
        return;
      }
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

  /// 获取小说正文缓存文件路径（key 带账号隔离，避免多账号缓存串用）
  Future<File> _novelTextCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/novel_text_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final uid = accountStore.now?.userId ?? 'guest';
    return File('${cacheDir.path}/novel_${uid}_$id.json');
  }

  /// 保存小说正文 JSON 到本地文件。
  /// 元数据恢复走 novelHistoryStore（.meta 文件是死写入，已删除）
  Future<void> _saveNovelTextToCache(String json) async {
    try {
      final file = await _novelTextCacheFile();
      await file.writeAsString(json);
    } catch (e) {
      print('_saveNovelTextToCache error: $e');
    }
  }

  /// 正文缓存 TTL：超过 30 天的缓存视为过期，读取时删除（防止磁盘无限增长）
  static const Duration _cacheTtl = Duration(days: 30);

  /// 从本地缓存加载小说正文
  Future<bool> _loadNovelTextFromCache() async {
    try {
      final file = await _novelTextCacheFile();
      if (!await file.exists()) return false;
      // 过期清理：超过 TTL 的缓存视为无效并删除
      try {
        final modified = await file.lastModified();
        if (DateTime.now().difference(modified) > _cacheTtl) {
          await file.delete();
          return false;
        }
      } catch (_) {
        // 读取修改时间失败不阻断加载（保守处理：允许继续读）
      }
      final json = await file.readAsString();
      novelTextResponse = NovelWebResponse.fromJson(jsonDecode(json));
      spans = await compute(buildSpans, novelTextResponse!);
      // 缓存命中但元数据缺失时，尝试从历史恢复，避免阅读页无限转圈
      if (novel == null) {
        novel = await _restoreNovelFromHistory();
        if (novel != null) {
          novelHistoryStore.insert(novel!);
        } else {
          // 元数据无法恢复则进入错误分支（带重试按钮），而非无出口的转圈
          errorMessage = '已加载缓存正文，但作品信息不可用';
          return true;
        }
      }
      errorMessage = null; // 清除错误状态
      fetchOffset();
      return true;
    } catch (e) {
      print('_loadNovelTextFromCache error: $e');
      return false;
    }
  }

  /// 从历史记录恢复小说元数据（方案 C）。
  /// 字段映射集中在 [Novel.fromPersist] 工厂中，此处只传历史记录的少量字段
  Future<Novel?> _restoreNovelFromHistory() async {
    try {
      await novelHistoryStore.novelPersistProvider.open();
      final all = await novelHistoryStore.novelPersistProvider.getAllAccount();
      final match = all.where((p) => p.novelId == id).toList();
      if (match.isNotEmpty) {
        final p = match.first;
        return Novel.fromPersist(
          id: p.novelId,
          title: p.title,
          userId: p.userId,
          userName: p.userName,
          pictureUrl: p.pictureUrl,
        );
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

  /// 解析函数已改用上游顶层 [parseNovelJsonFromHtml]（花括号配对解析）

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
    } catch (e) {
      // DB 读取失败仅影响阅读位置恢复，保留日志便于排查
      LPrinter.d("fetchOffset error: $e");
    }
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

String? parseNovelJsonFromHtml(String html) {
  final document = parse(html);
  for (final scriptElement in document.querySelectorAll('script')) {
    final scriptContent = scriptElement.innerHtml;
    final novelIndex = scriptContent.indexOf('novel:');
    if (novelIndex == -1) {
      continue;
    }
    final objectStart = scriptContent.indexOf('{', novelIndex);
    if (objectStart == -1) {
      continue;
    }
    return _readBalancedJsonObject(scriptContent, objectStart);
  }
  return null;
}

String? _readBalancedJsonObject(String source, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;

  for (var i = start; i < source.length; i++) {
    final char = source[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }

    if (char == '"') {
      inString = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  return null;
}
