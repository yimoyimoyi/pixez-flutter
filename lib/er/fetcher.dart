/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful, but WITHOUT ANY
 *  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 *  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with
 *  this program. If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io';

import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/er/toaster.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:pixez/store/save_store.dart';
import 'package:pixez/utils/haptic_util.dart';
import 'package:quiver/collection.dart';
import 'package:rhttp/rhttp.dart' as r;

enum IsoTaskState { INIT, APPEND, PROGRESS, ERROR, COMPLETE, RELOAD }

class IsoContactBean {
  final IsoTaskState state;
  final dynamic data;

  IsoContactBean({required this.state, required this.data});
}

class IsoProgressBean {
  final int min, total;
  final String url;

  IsoProgressBean({required this.min, required this.total, required this.url});
}

class TaskBean {
  String? url;
  Illusts? illusts;
  String? fileName;
  String? savePath;
  String? source;
  String? host;
  NetworkMode? networkMode;
  /// 主 isolate 入队时查询浏览缓存得到的文件路径（命中则下载 isolate
  /// 直接复制，零网络；miss 为 null 走网络下载）。
  /// 缓存库只在主 isolate 读写（单一写入者，避免双 isolate 互踩元数据）。
  String? cachedFilePath;

  TaskBean({
    required this.url,
    required this.illusts,
    required this.fileName,
    required this.savePath,
    this.networkMode,
    this.host,
    this.source,
    this.cachedFilePath,
  });
}

class NetworkReloadMessage {
  final NetworkMode networkMode;
  final String? source;

  NetworkReloadMessage({required this.networkMode, required this.source});
}

class Fetcher {
  BuildContext? context;
  List<TaskBean> queue = [];
  ReceivePort receivePort = ReceivePort();
  SendPort? sendPortToChild;
  Isolate? isolate;
  TaskPersistProvider taskPersistProvider = TaskPersistProvider();
  LruMap<String, JobEntity> jobMaps = LruMap();

  Fetcher() {}

  start(String pictureSource) async {
    if (receivePort.isBroadcast) return;
    await taskPersistProvider.open();
    await taskPersistProvider.getAllAccount();
    LPrinter.d("Fetcher start");
    receivePort.listen((message) {
      try {
        IsoContactBean isoContactBean = message;
        switch (isoContactBean.state) {
          case IsoTaskState.INIT:
            sendPortToChild = isoContactBean.data;
            break;
          case IsoTaskState.PROGRESS:
            IsoProgressBean isoProgressBean = isoContactBean.data;
            var job = fetcher.jobMaps[isoProgressBean.url];
            if (job != null) {
              job
                ..min = isoProgressBean.min
                ..status = 1
                ..max = isoProgressBean.total;
            } else {
              fetcher.jobMaps[isoProgressBean.url] = JobEntity()
                ..status = 1
                ..min = isoProgressBean.min
                ..max = isoProgressBean.total;
            }
            break;
          case IsoTaskState.COMPLETE:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            nextJob();
            _complete(
              taskBean.url!,
              taskBean.savePath!,
              taskBean.fileName!,
              taskBean.illusts!,
              cachedFilePath: taskBean.cachedFilePath,
            );
            break;
          case IsoTaskState.ERROR:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            nextJob();
            _errorD(taskBean.url!);
            break;
          default:
            break;
        }
      } catch (e) {}
    });
    isolate = await Isolate.spawn(
      entryPoint,
      SendMessage(
        receivePort.sendPort,
        pictureSource,
        userSetting.networkMode,
        RootIsolateToken.instance!,
      ),
      debugName: 'childIsolate',
    );
  }

  save(String url, Illusts illusts, String fileName) async {
    LPrinter.d(sendPortToChild.toString() + url);
    // 主 isolate 查询浏览缓存（缓存库唯一写入者在此）：
    // 命中则把文件路径传给下载 isolate 直接复制，零网络完成
    String? cachedFilePath;
    try {
      final fileInfo = await pixivCacheManager?.getFileFromCache(url);
      cachedFilePath = fileInfo?.file.path;
    } catch (e) {
      LPrinter.d("fetcher cache query failed: $e");
    }
    var taskBean = TaskBean(
      url: url,
      illusts: illusts,
      fileName: fileName,
      networkMode: userSetting.networkMode,
      source: userSetting.pictureSource,
      host: splashStore.host,
      savePath: (await getTemporaryDirectory()).path,
      cachedFilePath: cachedFilePath,
    );
    queue.add(taskBean);
    nextJob();
  }

  List<String> urlPool = [];

  nextJob() {
    if (queue.isNotEmpty && urlPool.length < userSetting.maxRunningTask) {
      TaskBean? first = null;
      for (var i in queue) {
        if (!urlPool.contains(i.url)) {
          first = i;
          break;
        }
      }
      if (first == null) return;
      first.networkMode = userSetting.networkMode;
      first.source = userSetting.pictureSource;
      first.host = splashStore.host;
      IsoContactBean isoContactBean = IsoContactBean(
        state: IsoTaskState.APPEND,
        data: first,
      );
      sendPortToChild?.send(isoContactBean);
      if (first.url != null) urlPool.add(first.url!);
    }
  }

  void stop() {
    isolate?.kill(priority: Isolate.immediate);
  }

  void reloadNetwork() {
    sendPortToChild?.send(
      IsoContactBean(
        state: IsoTaskState.RELOAD,
        data: NetworkReloadMessage(
          networkMode: userSetting.networkMode,
          source: userSetting.pictureSource,
        ),
      ),
    );
  }

  Future<void> _complete(
    String url,
    String savePath,
    String fileName,
    Illusts illusts, {
    String? cachedFilePath,
  }) async {
    var taskPersist = await taskPersistProvider.getAccount(url);
    if (taskPersist == null) return;
    await taskPersistProvider.update(taskPersist..status = 2);
    File file = File(savePath + Platform.pathSeparator + fileName);
    final uint8list = await file.readAsBytes();
    await saveStore.saveToGallery(uint8list, illusts, fileName);
    Toaster.downloadOk("${illusts.title} ${I18n.of(context!).saved}");
    // 网络下载完成 → 主 isolate 回填浏览缓存（缓存库唯一写入者）。
    // 缓存命中（cachedFilePath 非空）的任务无需回填，直接跳过
    if (cachedFilePath == null || cachedFilePath.isEmpty) {
      try {
        final uri = Uri.tryParse(url);
        final path = uri?.path ?? '';
        final dot = path.lastIndexOf('.');
        final fileExtension = dot == -1 ? null : path.substring(dot + 1);
        await pixivCacheManager?.putFileStream(
          url,
          file.openRead(),
          fileExtension: fileExtension ?? 'jpg',
        );
      } catch (e) {
        LPrinter.d("fetcher cache write-back failed: $e");
      }
    }
    var job = jobMaps[url];
    if (job != null) {
      job.status = 2;
    } else {
      jobMaps[url] = JobEntity()
        ..status = 2
        ..min = 1
        ..max = 1;
    }
  }

  Future<void> _errorD(String url) async {
    var taskPersist = await taskPersistProvider.getAccount(url);
    if (taskPersist == null) return;
    await taskPersistProvider.update(taskPersist..status = 3);
    HapticUtil.error();
    var job = jobMaps[url];
    if (job != null) {
      job.status = 3;
    } else {
      jobMaps[url] = JobEntity()
        ..status = 3
        ..min = 1
        ..max = 1;
    }
  }
}

class SendMessage {
  final SendPort sendPort;
  final String pictureSource;
  final NetworkMode networkMode;
  final RootIsolateToken rootIsolateToken;

  SendMessage(
    this.sendPort,
    this.pictureSource,
    this.networkMode,
    this.rootIsolateToken,
  );
}

entryPoint(SendMessage message) async {
  String pictureSource = message.pictureSource;
  var currentPictureSource = pictureSource;
  var currentNetworkMode = message.networkMode;
  RootIsolateToken rootIsolateToken = message.rootIsolateToken;
  SendPort sendPort = message.sendPort;
  LPrinter.d("entryPoint ====== $pictureSource");
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  await r.Rhttp.init();
  await Hoster.initMap();
  Hoster.dnsQueryFetcher();
  final dio = Dio();
  final client = await r.RhttpCompatibleClient.createSync(
    settings: PixezNetworkSettings.forImages(
      currentPictureSource,
      currentNetworkMode,
    ),
  );
  dio.interceptors.add(
    PixivImageSourceInterceptor(
      networkMode: () => currentNetworkMode,
      pictureSource: () => currentPictureSource,
    ),
  );
  dio.httpClientAdapter = ConversionLayerAdapter(client);
  // 注意：缓存库（dioCache 元数据）只在主 isolate 读写（单一写入者）。
  // 下载 isolate 不再自建 CacheManager——双 isolate 各自 3s debounce 整文件
  // 写回 dioCache.json 会互踩丢条目，导致浏览缓存失效、详情页原图重下载。
  // 缓存命中由主 isolate 在入队时查询并传入 cachedFilePath，回填由主
  // isolate 在收到 COMPLETE 后执行。
  ReceivePort receivePort = ReceivePort();
  sendPort.send(
    IsoContactBean(state: IsoTaskState.INIT, data: receivePort.sendPort),
  );

  receivePort.listen((message) async {
    try {
      IsoContactBean isoContactBean = message;
      if (isoContactBean.state == IsoTaskState.RELOAD) {
        final reload = isoContactBean.data as NetworkReloadMessage;
        currentNetworkMode = reload.networkMode;
        currentPictureSource = reload.source ?? PixezNetworkSettings.imageHost;
        final newClient = await r.RhttpCompatibleClient.createSync(
          settings: PixezNetworkSettings.forImages(
            currentPictureSource,
            currentNetworkMode,
          ),
        );
        dio.httpClientAdapter = ConversionLayerAdapter(newClient);
        return;
      }
      TaskBean taskBean = isoContactBean.data;
      switch (isoContactBean.state) {
        case IsoTaskState.ERROR:
          break;
        case IsoTaskState.APPEND:
          try {
            currentPictureSource = taskBean.source ?? pictureSource;
            currentNetworkMode = taskBean.networkMode ?? message.networkMode;
            LPrinter.d("taskBean.savePath: ${taskBean.savePath}");
            var savePath =
                taskBean.savePath! +
                Platform.pathSeparator +
                taskBean.fileName!;
            // 下载：优先使用主 isolate 入队时查到的浏览缓存文件（零网络），
            // miss 则 Dio 直下；缓存库读写均发生在主 isolate（单一写入者）
            const maxRetries = 2;
            bool success = false;
            Object? lastError;
            final cachedFile = taskBean.cachedFilePath;
            if (cachedFile != null && cachedFile.isNotEmpty) {
              try {
                final file = File(savePath);
                if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
                await File(cachedFile).copy(file.path);
                success = true;
                sendPort.send(IsoContactBean(state: IsoTaskState.COMPLETE, data: taskBean));
              } catch (e) {
                // 缓存文件已被驱逐/删除：回退到网络下载
                LPrinter.d("fetcher cache copy failed, fallback to network: $e");
              }
            }
            if (!success) {
              for (int attempt = 0; attempt < maxRetries; attempt++) {
                try {
                  final resp = await dio.get<List<int>>(
                    taskBean.url!,
                    options: Options(
                      headers: {
                        "referer": "https://app-api.pixiv.net/",
                        "User-Agent": "PixivIOSApp/5.8.0",
                      },
                      responseType: ResponseType.bytes,
                      receiveTimeout: const Duration(seconds: 30),
                    ),
                    onReceiveProgress: (min, total) {
                      sendPort.send(IsoContactBean(
                        state: IsoTaskState.PROGRESS,
                        data: IsoProgressBean(
                          min: min,
                          total: total > 0 ? total : min + 1,
                          url: taskBean.url!,
                        ),
                      ));
                    },
                  );
                  if (resp.data != null && resp.data!.isNotEmpty) {
                    final file = File(savePath);
                    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
                    await file.writeAsBytes(resp.data!);
                    // 回填浏览缓存由主 isolate 在 COMPLETE 处理后执行
                    //（单一写入者，避免双 isolate 并发写缓存元数据互踩）。
                    // 置空 cachedFilePath：若此前缓存 copy 失败回退到网络，
                    // 需告知主 isolate 本次为网络下载、应执行回填
                    taskBean.cachedFilePath = null;
                    success = true;
                    sendPort.send(IsoContactBean(state: IsoTaskState.COMPLETE, data: taskBean));
                    break;
                  }
                } catch (e) {
                  lastError = e;
                  LPrinter.d("fetcher Dio attempt $attempt failed: $e");
                  if (attempt < maxRetries - 1) {
                    await Future.delayed(Duration(seconds: 2 << attempt));
                  }
                }
              }
            }
            if (!success) {
              LPrinter.d("fetcher all retries failed: $lastError");
              sendPort.send(
                IsoContactBean(state: IsoTaskState.ERROR, data: taskBean),
              );
            }
          } catch (e) {
            LPrinter.d("fetcher=======");
            LPrinter.d(e);
            sendPort.send(
              IsoContactBean(state: IsoTaskState.ERROR, data: taskBean),
            );
          }
          break;
        default:
          break;
      }
    } catch (e) {
      LPrinter.d(e);
    }
  });
}
