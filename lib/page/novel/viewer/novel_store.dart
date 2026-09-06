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
import 'package:pixez/translation/translation_config.dart';
import 'package:pixez/translation/translation_service.dart';
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

  // ---------- 全文翻译（novelBody 类型） ----------
  @observable
  bool novelTranslating = false;
  @observable
  int novelTranslatedSpans = 0;
  @observable
  int novelTotalSpans = 0;
  @observable
  int novelTranslatedChars = 0;
  @observable
  int novelTotalChars = 0;
  /// 失败的段落数（译文==原文/空等被校验拒绝，未写缓存，可重试）
  @observable
  int novelFailedSpans = 0;
  /// 是否已完成全文翻译（成功/部分完成/中止，供 UI 区分状态）
  @observable
  bool novelTranslateDone = false;
  int _translateEpoch = 0;

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

  /// 可翻译 span 谓词：正常类型、非空、非 `[` 开头（回退键）、不含 URL（jumpuri 回退产物）
  static bool isTranslatableSpan(NovelSpansData span) =>
      isTranslatableNovelSpan(span);

  /// 全文翻译入口：以 \n 段落为翻译单元，按用户配置的批容量分批入队，
  /// 每批可附前一段原文作上下文（useNovelContext）；可取消（epoch 令牌）、
  /// 已译段落自动跳过（续传）。
  @action
  Future<void> translateFullText() async {
    final service = TranslationService.instance;
    const type = TranslateContentType.novelBody;
    if (!service.isTypeEnabled(type) || novelTranslating) return;

    final spansSnapshot = List<NovelSpansData>.from(spans);
    // 段落级单元：span 索引 -> 段落原文
    final paras = <MapEntry<int, String>>[];
    for (var i = 0; i < spansSnapshot.length; i++) {
      if (!isTranslatableSpan(spansSnapshot[i])) continue;
      for (final seg in spansSnapshot[i].text.split('\n')) {
        if (seg.trim().isEmpty) continue;
        paras.add(MapEntry(i, seg));
      }
    }
    if (paras.isEmpty) return;

    final epoch = ++_translateEpoch;
    final engineId = service.config.effectiveEngineFor(type);
    final target = service.resolveTargetLang();
    final batchChars = service.config.novelBatchChars;
    final batchSpanCap = service.config.novelBatchSpanCap;
    final useContext = service.config.useNovelContext;

    novelTotalSpans = paras.length; // 进度单位为"段落"
    novelTranslatedSpans = 0;
    novelTotalChars = paras.fold<int>(0, (acc, e) => acc + e.value.length);
    novelTranslatedChars = 0;
    novelFailedSpans = 0;
    novelTranslateDone = false;
    novelTranslating = true;

    try {
      final batchIdxGroups = buildNovelBatches(
        paras.map((e) => e.value).toList(),
        batchSpanCap: batchSpanCap,
        batchChars: batchChars,
      );
      // 提交窗口：一次排队 ≤ 2×maxConcurrency 批，组内提交后等待该组完成。
      // 队列内的信号量限制真正在途并发数（切勿逐批 await 提交，否则退化为串行）。
      // 取消/配置变化在窗口边界生效（已提交批自然完成并计入进度）。
      final windowSize = (service.config.maxConcurrency * 2).clamp(2, 20);
      var next = 0;
      while (next < batchIdxGroups.length) {
        if (epoch != _translateEpoch) break; // 取消：停止提交新批
        // 配置/参数中途变化（换引擎/目标语言/开关）→ 中止避免译文混杂
        if (service.config.effectiveEngineFor(type) != engineId ||
            service.resolveTargetLang() != target) {
          _translateEpoch = epoch + 1;
          break;
        }
        final groupFutures = <Future<void>>[];
        while (next < batchIdxGroups.length &&
            groupFutures.length < windowSize) {
          final group = batchIdxGroups[next];
          groupFutures.add(_submitBatch(
            group: group,
            paras: paras,
            type: type,
            service: service,
            useContext: useContext,
            epoch: epoch,
          ));
          next++;
        }
        try {
          await Future.wait(groupFutures);
        } catch (_) {}
      }
    } catch (e) {
      LPrinter.d('novel translate full failed: $e');
    } finally {
      novelTranslating = false;
      novelTranslateDone = true;
    }
  }

  /// 提交并执行一批（进度在完成回调更新，无需顺序完成）
  Future<void> _submitBatch({
    required List<int> group,
    required List<MapEntry<int, String>> paras,
    required TranslateContentType type,
    required TranslationService service,
    required bool useContext,
    required int epoch,
  }) async {
    final batchParas = group.map((i) => paras[i].value).toList();
    // 上下文段提示：批首段的前一段原文（末尾 ≤1200 字符）
    String? contextText;
    final firstIdx = group.first;
    if (useContext && firstIdx > 0) {
      var ctx = paras[firstIdx - 1].value;
      if (ctx.length > 1200) {
        ctx = ctx.substring(ctx.length - 1200);
      }
      contextText = ctx;
    }
    try {
      await service.enqueueTexts(batchParas, type, contextText: contextText);
    } catch (_) {
      // 批次失败不阻塞其它批（队列内已静默回退，这里仅保证进度推进）
    }
    // 批执行完成后按"段落是否有译文"精确记账：
    // 已在缓存/本次成功 → 进度+；仍无译文（失败/被校验拒绝）→ 失败计数+（可重试）
    var done = 0;
    var failed = 0;
    var doneChars = 0;
    for (final i in group) {
      if (service.hasTranslationOf(paras[i].value, type)) {
        done++;
        doneChars += paras[i].value.length;
      } else {
        failed++;
      }
    }
    novelTranslatedSpans = (novelTranslatedSpans + done) > novelTotalSpans
        ? novelTotalSpans
        : novelTranslatedSpans + done;
    novelFailedSpans = (novelFailedSpans + failed) > novelTotalSpans
        ? novelTotalSpans
        : novelFailedSpans + failed;
    novelTranslatedChars = (novelTranslatedChars + doneChars) > novelTotalChars
        ? novelTotalChars
        : novelTranslatedChars + doneChars;
  }

  /// 取消全文翻译：在途批的 HTTP 不中断（结果写入缓存，重进可复用），仅中止后续批次
  @action
  void cancelTranslateFullText() {
    _translateEpoch++;
    novelTranslating = false;
    novelTranslateDone = true;
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

/// 可翻译 span 谓词：正常类型、非空、非 `[` 开头（回退键）、不含 URL（jumpuri 回退产物）。
/// 顶层函数以便 novel_store/novel_viewer/单测共享。
bool isTranslatableNovelSpan(NovelSpansData span) {
  if (span.type != NovelSpansType.normal) return false;
  final text = span.text.trim();
  if (text.isEmpty) return false;
  if (text.startsWith('[')) return false;
  if (RegExp(r'https?://\S+').hasMatch(text)) return false;
  return true;
}

/// 统计可译段落数与字符数（\n 拆段、过滤空白段），供进度预估与循环共用。
/// 顶层函数以便 novel_viewer/novel_store 共享（mixin 类的 static 不可经用户类访问）。
({int parasCount, int charsCount}) novelTranslatableStats(
    List<NovelSpansData> spans) {
  var paras = 0;
  var chars = 0;
  for (final span in spans) {
    if (!_NovelStoreBase.isTranslatableSpan(span)) continue;
    for (final seg in span.text.split('\n')) {
      if (seg.trim().isEmpty) continue;
      paras++;
      chars += seg.length;
    }
  }
  return (parasCount: paras, charsCount: chars);
}

/// 批量分组：以段落数为主、字符数为兜底；单段超预算时单独成批。
/// 返回段落索引分组（保持原顺序），供 novel_store 循环与单测共用。
List<List<int>> buildNovelBatches(
  List<String> paras, {
  required int batchSpanCap,
  required int batchChars,
}) {
  final batches = <List<int>>[];
  var idx = 0;
  while (idx < paras.length) {
    final batch = <int>[];
    var chars = 0;
    while (idx < paras.length) {
      final len = paras[idx].length;
      if (batch.isNotEmpty &&
          (batch.length >= batchSpanCap || chars + len > batchChars)) {
        break;
      }
      batch.add(idx);
      chars += len;
      idx++;
    }
    if (batch.isEmpty) break;
    batches.add(batch);
  }
  return batches;
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
