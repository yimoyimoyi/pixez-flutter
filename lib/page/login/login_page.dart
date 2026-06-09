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
                      // 1) Token 登录 — rhttp compat 直连
                      FilledButton.icon(
                        icon: Icon(Icons.vpn_key_outlined),
                        label: Text(I18n.of(context).login),
                        onPressed: () async {
                          Leader.push(context, TokenPage());
                        },
                      ),
                      SizedBox(height: 12),
                      // 2) 内部 WebView — 直连（需要系统代理/VPN）
                      OutlinedButton.icon(
                        icon: Icon(Icons.web),
                        label: Text("内部 WebView"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchWebView(url);
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
                            _launchWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 12),
                      // 3) 外部浏览器
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

  /// 内部 WebView — 直连加载原始 URL
  Future<void> _launchWebView(String url) async {
    if (Platform.isIOS || Platform.isMacOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    try {
      await Leader.push(context, WebViewPage(url: url));
    } catch (e) {
      BotToast.showText(text: "WebView 登录失败: $e");
    }
  }

  /// 外部浏览器
  Future<void> _launchExternal(String url) async {
    if (Platform.isIOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    if (Platform.isMacOS) {
      try { CustomTabPlugin.launch(url); } catch (e) { BotToast.showText(text: e.toString()); }
      return;
    }
    try { await CustomTabPlugin.launch(url); } catch (e) { BotToast.showText(text: "浏览器不可用: $e"); }
  }
}
