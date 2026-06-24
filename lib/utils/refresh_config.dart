/// EasyRefresh 统一配置
/// 集中管理所有刷新相关的配置参数

import 'dart:io';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:pixez/component/pixez_default_header.dart';

class RefreshConfig {
  /// iOS 和 Android 的上拉加载触发偏移量
  static double get callLoadOverOffset => Platform.isIOS ? 2.0 : 5.0;

  /// 统一的 Header 配置
  static Header header(BuildContext context,
      {IndicatorPosition position = IndicatorPosition.above,
      bool safeArea = true}) {
    return PixezDefault.header(context,
        position: position, safeArea: safeArea);
  }

  /// 统一的 Footer 配置
  static Footer footer(BuildContext context,
      {IndicatorPosition position = IndicatorPosition.above}) {
    return PixezDefault.footer(context, position: position);
  }

  /// 创建 EasyRefreshController 的工厂方法
  static EasyRefreshController createController() {
    return EasyRefreshController(
      controlFinishLoad: true,
      controlFinishRefresh: true,
    );
  }
}
