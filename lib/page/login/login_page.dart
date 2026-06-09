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
import 'package:flutter/material.dart';
import 'package:pixez/custom_tab_plugin.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/oauth_client.dart';
import 'package:pixez/page/about/about_page.dart';
import 'package:pixez/page/hello/setting/setting_quality_page.dart';
import 'package:pixez/page/login/token_page.dart';
import 'package:pixez/page/webview/webview_page.dart';
import 'package:pixez/er/login_proxy.dart';
import 'package:pixez/er/pixiv_vpn_plugin.dart';
import 'package:pixez/er/v2ray_config.dart';
import 'package:pixez/er/v2ray_manager.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LoginPage extends StatefulWidget {
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            IconButton(
              icon: Icon(Icons.settings),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => SettingQualityPage()),
                );
              },
            ),
            IconButton(
              icon: Icon(Icons.message),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => AboutPage()),
                );
              },
            ),
          ],
        ),
      ),
      appBar: AppBar(elevation: 0.0, backgroundColor: Colors.transparent),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Builder(
        builder: (context) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Container(
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(0),
          child: Column(
            children: <Widget>[
              Container(height: 20),
              Image.asset('assets/images/icon.png', height: 80, width: 80),
              Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(height: 10),
                      // 1) Token 登录 — rhttp compat 直连，默认主方案
                      FilledButton.icon(
                        icon: Icon(Icons.vpn_key_outlined),
                        label: Text(I18n.of(context).login),
                        onPressed: () async {
                          Leader.push(context, TokenPage());
                        },
                      ),
                      SizedBox(height: 12),
                      // 2) Http Proxy 登录 — 能加载页面，reCAPTCHA 可能报错
                      OutlinedButton.icon(
                        icon: Icon(Icons.web),
                        label: Text("内部 WebView (Proxy)"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchProxyWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 4),
                      OutlinedButton.icon(
                        icon: Icon(Icons.person_add),
                        label: Text(I18n.of(context).dont_have_account),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl(create: true);
                            _launchProxyWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 8),
                      // 3) VpnService DNS 劫持 — 实验性
                      OutlinedButton.icon(
                        icon: Icon(Icons.vpn_lock),
                        label: Text("内部 WebView (VPN)"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchVpnWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 12),
                      Divider(),
                      SizedBox(height: 4),
                      // 4) 外部浏览器
                      OutlinedButton.icon(
                        icon: Icon(Icons.open_in_browser),
                        label: Text("外部浏览器"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchExternal(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 4),
                      TextButton(
                        child: Text(I18n.of(context).terms),
                        onPressed: () async {
                          try {
                            await launchUrlString('https://www.pixiv.net/terms/?page=term');
                          } catch (e) {}
                        },
                      ),
                    ],
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 外部浏览器登录
  Future<void> _launchExternal(String url) async {
    // iOS/macOS: 仅使用 WebView 或系统浏览器
    if (Platform.isIOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    if (Platform.isMacOS) {
      try {
        CustomTabPlugin.launch(url);
      } catch (e) {
        BotToast.showText(text: e.toString());
      }
      return;
    }
    // Android: Chrome Custom Tab / 系统浏览器
    try {
      await CustomTabPlugin.launch(url);
    } catch (e) {
      BotToast.showText(text: "浏览器不可用: $e");
    }
  }

  /// HTTP Proxy 登录 — LoginProxy HTTP，页面能加载但 reCAPTCHA 可能报 localhost 错误
  Future<void> _launchProxyWebView(String url) async {
    if (Platform.isIOS || Platform.isMacOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    try {
      var finalUrl = url;
      if (userSetting.networkMode.usesCompatibleConnection) {
        await LoginProxy.start();
        finalUrl = LoginProxy.proxyUrl(url);
      }
      await Leader.push(context, WebViewPage(url: finalUrl));
    } catch (e) {
      BotToast.showText(text: "Proxy 登录失败: $e");
    }
  }

  /// V2Ray VPN 登录 — 无节点路由，Pixiv 走 LoginProxy，其他直连
  Future<void> _launchVpnWebView(String url) async {
    if (Platform.isIOS || Platform.isMacOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    try {
      if (userSetting.networkMode.usesCompatibleConnection) {
        // 1. 启动 LoginProxy HTTPS
        await LoginProxy.startHttps();

        // 2. 启动 V2Ray VPN（无节点，纯本地路由）
        // 先用直通模式测试 V2Ray TUN+DNS 是否正常
        final config = V2RayConfig.testDirect();
        final ok = await V2RayManager.start(config: config);
        if (!ok) {
          BotToast.showText(text: "VPN 权限未授予");
          await LoginProxy.stop();
          return;
        }
      }
      // 3. WebView 加载真实 URL（DNS/traffic 由 V2Ray 处理）
      await Leader.push(context, WebViewPage(url: url));
    } catch (e) {
      BotToast.showText(text: "VPN 登录失败: $e");
    }
  }
}
