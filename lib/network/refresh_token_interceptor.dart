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

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/account.dart';
import 'package:pixez/models/error_message.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/network/oauth_client.dart';

class RefreshTokenInterceptor extends QueuedInterceptorsWrapper {
  static Completer<void>? _refreshCompleter;

  Future<String?> getToken() async {
    String? token = accountStore.now?.accessToken;
    if (token != null && token.isNotEmpty) {
      return "Bearer " + token;
    } else {
      try {
        AccountProvider accountProvider = AccountProvider();
        await accountProvider.open();
        final all = await accountProvider.getAllAccount();
        if (all.isEmpty) return null;
        final index = accountStore.index;
        if (index < 0 || index >= all.length) {
          return "Bearer " + all.first.accessToken;
        }
        return "Bearer " + all[index].accessToken;
      } catch (e) {
        return null;
      }
    }
  }

  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // 动态生成最新 X-Client-Time 和 X-Client-Hash
    final time = ApiClient.getIsoDate();
    options.headers["X-Client-Time"] = time;
    options.headers["X-Client-Hash"] = ApiClient.getHash(time + apiClient.hashSalt);

    if (!options.path.contains('v1/walkthrough/illusts')) {
      options.headers[OAuthClient.AUTHORIZATION] = await getToken();
      if (options.headers[OAuthClient.AUTHORIZATION] == null) {
        return handler.reject(DioException(requestOptions: options));
      }
    }
    return handler.next(options);
  }

  int bti(bool bool) {
    if (bool) {
      return 1;
    } else
      return 0;
  }

  int lastRefreshTime = 0;

  // 重试计数改为 per-request（存入 options.extra），避免跨请求共享计数错乱
  static const _retryCountKey = 'refresh_token_retry_count';

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    return handler.next(response);
  }

  @override
  void onError(DioException err, handler) async {
    if (err.response != null && err.response!.statusCode == 400) {
      if (_refreshCompleter != null) {
        // 已有处于刷新流程中的请求，等待其完成
        try {
          await _refreshCompleter!.future;
        } catch (_) {}
      } else {
        DateTime dateTime = DateTime.now();
        if ((dateTime.millisecondsSinceEpoch - lastRefreshTime) > 200000) {
          _refreshCompleter = Completer<void>();
          try {
            print("lock start ========================");
            ErrorMessage errorMessage = ErrorMessage.fromJson(err.response!.data);
            if (errorMessage.error.message!.contains("OAuth") &&
                accountStore.now != null) {
              final client = OAuthClient();
              await client.createDioClient();
              AccountPersist accountPersist = accountStore.now!;
              Response response1 = await client.postRefreshAuthToken(
                  refreshToken: accountPersist.refreshToken,
                  deviceToken: accountPersist.deviceToken);
              AccountResponse accountResponse =
                  Account.fromJson(response1.data).response;
              final user = accountResponse.user;
              await accountStore.updateSingle(AccountPersist(
                  userId: user.id,
                  userImage: user.profileImageUrls.px170x170,
                  accessToken: accountResponse.accessToken,
                  refreshToken: accountResponse.refreshToken,
                  deviceToken: "",
                  passWord: "no more",
                  name: user.name,
                  account: user.account,
                  mailAddress: user.mailAddress,
                  isPremium: bti(user.isPremium),
                  xRestrict: user.xRestrict,
                  isMailAuthorized: bti(user.isMailAuthorized),
                  id: accountPersist.id));
              lastRefreshTime = DateTime.now().millisecondsSinceEpoch;
              print("unlock ========================");
              _refreshCompleter?.complete();
            } else {
              lastRefreshTime = 0;
              print("unlock ========================");
              _refreshCompleter?.complete();
              _refreshCompleter = null;
              return handler.reject(err);
            }
          } catch (e) {
            print(e);
            lastRefreshTime = 0;
            print("unlock ========================");
            _refreshCompleter?.completeError(e);
            _refreshCompleter = null;
            return handler.reject(err);
          } finally {
            _refreshCompleter = null;
          }
        }
      }
      var option = err.requestOptions;
      final newToken = (await getToken());
      print("unlock retry ======================== $newToken");
      option.headers[OAuthClient.AUTHORIZATION] = newToken;
      try {
        var response = await apiClient.httpClient.request(
          option.path,
          data: option.data,
          queryParameters: option.queryParameters,
          cancelToken: option.cancelToken,
          options: Options(
            method: option.method,
            headers: option.headers,
            contentType: option.contentType,
            extra: option.extra,
          ),
        );
        return handler.resolve(response);
      } catch (e) {
        if (e is DioException) {
          return handler.reject(e);
        }
        return handler.reject(err);
      }
    }
    // 自动重试：仅在没有收到响应时（连接/传输层错误），上限 2 次（per-request 计数）
    final retryNum = err.requestOptions.extra[_retryCountKey] as int? ?? 0;
    if (err.response == null && retryNum < 2) {
      final errMsg = '${err.message ?? ''} ${err.error ?? ''}';
      final shouldRetry = err.type == DioExceptionType.unknown ||
          err.type == DioExceptionType.connectionError ||
          err.type == DioExceptionType.connectionTimeout ||
          err.type == DioExceptionType.receiveTimeout ||
          errMsg.contains('IncompleteMessage') ||
          errMsg.contains('Connection closed') ||
          errMsg.contains('broken pipe');
      if (shouldRetry) {
        final safeMsg = errMsg.length > 100 ? errMsg.substring(0, 100) : errMsg;
        print('retry $retryNum ========= ${err.type}: $safeMsg');
        await Future.delayed(Duration(milliseconds: 300 << retryNum));
        try {
          RequestOptions options = err.requestOptions;
          var response = await apiClient.httpClient.request(
            options.path,
            options: Options(
              method: options.method,
              headers: options.headers,
              contentType: options.contentType,
              extra: {...options.extra, _retryCountKey: retryNum + 1},
            ),
            data: options.data,
            queryParameters: options.queryParameters,
            cancelToken: options.cancelToken,
          );
          return handler.resolve(response);
        } catch (e) {
          print('retry $retryNum failed: $e');
        }
      }
    }
    return handler.reject(err);
  }
}
