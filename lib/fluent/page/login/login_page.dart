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

import 'package:bot_toast/bot_toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixez/custom_tab_plugin.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/fluent/page/login/token_page.dart';
import 'package:pixez/fluent/page/webview/webview_page.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/oauth_client.dart';
import 'package:pixez/er/login_proxy.dart';
import 'package:pixez/er/pixiv_vpn_plugin.dart';
import 'package:pixez/er/v2ray_config.dart';
import 'package:pixez/er/v2ray_manager.dart';
import 'package:pixez/fluent/page/about/about_page.dart';
import 'package:pixez/fluent/page/hello/setting/setting_quality_page.dart';

class LoginPage extends StatefulWidget {
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      bottomBar: CommandBar(
        primaryItems: [
          CommandBarButton(
            icon: Icon(FluentIcons.settings),
            onPressed: () {
              Leader.push(
                context,
                SettingQualityPage(),
                icon: Icon(FluentIcons.settings),
                title: Text(I18n.of(context).quality_setting),
              );
            },
          ),
          CommandBarButton(
            icon: Icon(FluentIcons.message),
            onPressed: () {
              Leader.push(
                context,
                AboutPage(),
                icon: Icon(FluentIcons.message),
                title: Text(I18n.of(context).about),
              );
            },
          ),
        ],
      ),
      content: Builder(
        builder: (context) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return FluentTheme(
      data: FluentThemeData(
        accentColor: FluentTheme.of(context).accentColor,
        brightness: FluentTheme.of(context).brightness,
      ),
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
                    children: <Widget>[
                      SizedBox(height: 10),
                      // 1) Token 登录 — rhttp compat 直连
                      FilledButton(
                        child: Text(I18n.of(context).login),
                        onPressed: () async {
                          await showDialog(
                            context: context,
                            builder: (context) => TokenPage(),
                          );
                        },
                      ),
                      SizedBox(height: 8),
                      // 2) Http Proxy 登录
                      Button(
                        child: Text("内部 WebView (Proxy)"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchProxyWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 4),
                      Button(
                        child: Text(I18n.of(context).dont_have_account),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl(create: true);
                            _launchProxyWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 4),
                      // 3) VpnService 实验性
                      Button(
                        child: Text("内部 WebView (VPN)"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchVpnWebView(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 8),
                      Divider(),
                      // 4) 外部浏览器
                      Button(
                        child: Text("外部浏览器"),
                        onPressed: () async {
                          try {
                            final url = await OAuthClient.generateWebviewUrl();
                            _launchExternal(url);
                          } catch (e) {}
                        },
                      ),
                      SizedBox(height: 4),
                      HyperlinkButton(
                        child: Text(I18n.of(context).terms),
                        onPressed: () async {
                          try {
                            await _launchExternal('https://www.pixiv.net/terms/?page=term');
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

  Future<void> _launchExternal(String url) async {
    try {
      await CustomTabPlugin.launch(url);
    } catch (e) {
      BotToast.showText(text: "浏览器不可用: $e");
    }
  }

  Future<void> _launchProxyWebView(String url) async {
    try {
      var finalUrl = url;
      if (userSetting.networkMode.usesCompatibleConnection) {
        await LoginProxy.start();
        finalUrl = LoginProxy.proxyUrl(url);
      }
      await Leader.push(
        context,
        WebViewPage(url: finalUrl),
        icon: Icon(FluentIcons.signin),
        title: Text(I18n.of(context).login),
      );
    } catch (e) {
      BotToast.showText(text: "Proxy 登录失败: $e");
    }
  }

  Future<void> _launchVpnWebView(String url) async {
    try {
      if (userSetting.networkMode.usesCompatibleConnection) {
        await LoginProxy.startHttps();
        final config = V2RayConfig.generate();
        final ok = await V2RayManager.start(config: config);
        if (!ok) {
          BotToast.showText(text: "VPN 权限未授予");
          await LoginProxy.stop();
          return;
        }
      }
      await Leader.push(
        context,
        WebViewPage(url: url),
        icon: Icon(FluentIcons.signin),
        title: Text(I18n.of(context).login),
      );
    } catch (e) {
      BotToast.showText(text: "VPN 登录失败: $e");
    }
  }
}
