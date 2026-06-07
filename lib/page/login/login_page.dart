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
import 'package:pixez/models/account.dart';
import 'package:pixez/network/oauth_client.dart';
import 'package:pixez/page/about/about_page.dart';
import 'package:pixez/page/hello/setting/setting_quality_page.dart';
import 'package:pixez/page/login/token_page.dart';
import 'package:pixez/page/webview/webview_page.dart';
import 'package:pixez/weiss_plugin.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LoginPage extends StatefulWidget {
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  TextEditingController userNameController = TextEditingController();
  TextEditingController passWordController = TextEditingController();
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    userNameController.dispose();
    passWordController.dispose();
    super.dispose();
  }

  Future<void> _doPasswordLogin() async {
    if (userNameController.text.isEmpty || passWordController.text.isEmpty) return;
    setState(() { _loading = true; _error = ''; });
    try {
      final resp = await oAuthClient.postAuthToken(
        userNameController.text.trim(),
        passWordController.text.trim(),
      );
      final accountResp =
          Account.fromJson(resp.data).response;
      final user = accountResp.user;
      final provider = AccountProvider();
      await provider.open();
      await provider.deleteByUserId(user.id);
      await provider.insert(AccountPersist(
        userId: user.id,
        userImage: user.profileImageUrls.px170x170,
        accessToken: accountResp.accessToken,
        refreshToken: accountResp.refreshToken,
        deviceToken: "",
        passWord: passWordController.text.trim(),
        name: user.name,
        account: user.account,
        mailAddress: user.mailAddress,
        isPremium: user.isPremium ? 1 : 0,
        xRestrict: user.xRestrict,
        isMailAuthorized: user.isMailAuthorized ? 1 : 0,
      ));
      await accountStore.fetch();
      if (mounted) Leader.pushUntilHome(context);
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

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
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (context) => AboutPage()));
              },
            ),
          ],
        ),
      ),
      appBar: AppBar(elevation: 0.0, backgroundColor: Colors.transparent),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Builder(
        builder: (context) {
          return _buildBody(context);
        },
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
                  child: Container(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(height: 10),
                        FilledButton(
                          child: Text(I18n.of(context).login),
                          onPressed: () async {
                            try {
                              String url =
                                  await OAuthClient.generateWebviewUrl();
                              _launch(url);
                            } catch (e) {}
                          },
                        ),
                        SizedBox(height: 4),
                        FilledButton(
                          onPressed: () async {
                            try {
                              String url = await OAuthClient.generateWebviewUrl(
                                create: true,
                              );
                              _launch(url);
                            } catch (e) {}
                          },
                          child: Text(I18n.of(context).dont_have_account),
                        ),
                        SizedBox(height: 4),
                        // 用户名密码直登 — rhttp compat 直连，无需浏览器
                        TextField(
                          controller: userNameController,
                          decoration: InputDecoration(
                            prefixIcon: Icon(Icons.person_outline),
                            hintText: 'Pixiv ID / Email',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                        SizedBox(height: 8),
                        TextField(
                          controller: passWordController,
                          decoration: InputDecoration(
                            prefixIcon: Icon(Icons.lock_outline),
                            hintText: 'Password',
                            border: OutlineInputBorder(),
                          ),
                          obscureText: true,
                        ),
                        SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: _loading
                                ? SizedBox(width: 16, height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Icon(Icons.login, size: 16),
                            label: Text(_loading ? '...' : '直连登录'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            ),
                            onPressed: _loading ? null : _doPasswordLogin,
                          ),
                        ),
                        if (_error.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(_error, style: TextStyle(color: Colors.red, fontSize: 12)),
                          ),
                        SizedBox(height: 12),
                        Divider(),
                        SizedBox(height: 4),
                        // Token 备用
                        OutlinedButton.icon(
                          icon: Icon(Icons.vpn_key_outlined, size: 16),
                          label: Text("Token"),
                          onPressed: () async {
                            Leader.push(context, TokenPage());
                          },
                        ),
                        SizedBox(height: 4),
                        TextButton(
                          child: Text(I18n.of(context).terms),
                          onPressed: () async {
                            final url =
                                'https://www.pixiv.net/terms/?page=term';
                            try {
                              await launchUrlString(url);
                            } catch (e) {}
                          },
                        ),
                      ],
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _launch(String url) async {
    // iOS: 使用 WebView
    if (Platform.isIOS) {
      final result = await Leader.push(context, WebViewPage(url: url));
      if (result == "OK") Leader.pushUntilHome(context);
      return;
    }
    // macOS: 使用系统浏览器
    if (Platform.isMacOS) {
      try {
        CustomTabPlugin.launch(url);
      } catch (e) {
        BotToast.showText(text: e.toString());
      }
      return;
    }
    // Android: 优先外部浏览器（利用系统代理/VPN）
    // 失败则回退 WebView + Weiss 本地代理
    try {
      await CustomTabPlugin.launch(url);
    } catch (e) {
      BotToast.showText(text: I18n.of(context).login);
      try {
        if (userSetting.networkMode.usesCompatibleConnection) {
          await WeissPlugin.start();
          await WeissPlugin.proxy();
        }
        Leader.push(context, WebViewPage(url: url));
      } catch (e2) {
        BotToast.showText(text: e2.toString());
      }
    }
  }
}
