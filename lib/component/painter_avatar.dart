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
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/user/users_page.dart';

class PainterAvatar extends StatefulWidget {
  final String url;
  final int id;
  final GestureTapCallback? onTap;
  final Size? size;

  const PainterAvatar(
      {Key? key, required this.url, required this.id, this.onTap, this.size})
      : super(key: key);

  @override
  _PainterAvatarState createState() => _PainterAvatarState();
}

class _PainterAvatarState extends State<PainterAvatar> {
  Uint8List? _cachedBytes;

  void pushToUserPage() {
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) {
      return UsersPage(id: widget.id);
    }));
  }

  /// 方案 B: 尝试从本地文件缓存加载头像
  Future<void> _tryLoadFromCache() async {
    if (_cachedBytes != null) return;
    try {
      final sourceUrl = PixivImageSource.resolve(
        widget.url,
        networkMode: userSetting.networkMode,
        pictureSource: userSetting.pictureSource,
      );
      final fileInfo = await pixivCacheManager?.getFileFromCache(sourceUrl);
      if (fileInfo != null && mounted) {
        final bytes = fileInfo.file.readAsBytesSync();
        if (bytes.isNotEmpty) setState(() => _cachedBytes = bytes);
      }
    } catch (_) {}
  }

  Widget? _buildCachedAvatar(double size) {
    if (_cachedBytes != null) {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(image: MemoryImage(_cachedBytes!), fit: BoxFit.cover),
        ),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cachedWidget = widget.size == null
        ? _buildCachedAvatar(60.0)
        : _buildCachedAvatar(widget.size!.width);
    if (cachedWidget != null) {
      return GestureDetector(
        onTap: () {
          if (widget.onTap == null) pushToUserPage();
          else widget.onTap!();
        },
        child: cachedWidget,
      );
    }

    return GestureDetector(
        onTap: () {
          if (widget.onTap == null) {
            pushToUserPage();
          } else
            widget.onTap!();
        },
        child: widget.size == null
            ? CachedNetworkImage(
                imageUrl: widget.url,
                imageBuilder: (context, imageProvider) => Container(
                  width: 60.0,
                  height: 60.0,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    image: DecorationImage(
                        image: imageProvider, fit: BoxFit.cover),
                  ),
                ),
                placeholder: (context, url) => Container(
                  width: 60.0,
                  height: 60.0,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).cardColor),
                ),
                httpHeaders: Hoster.header(url: widget.url),
                cacheManager: pixivCacheManager,
                errorWidget: (context, url, error) {
                  _tryLoadFromCache(); // 方案 B: 网络失败后尝试缓存
                  return Container(
                    width: 60.0,
                    height: 60.0,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).cardColor),
                  );
                },
              )
            : CachedNetworkImage(
                imageUrl: widget.url,
                cacheManager: pixivCacheManager,
                placeholder: (context, url) => Container(
                  width: widget.size!.width,
                  height: widget.size!.height,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).cardColor),
                ),
                errorWidget: (context, url, error) {
                  _tryLoadFromCache(); // 方案 B
                  return Container(
                    width: widget.size!.width,
                    height: widget.size!.height,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).cardColor),
                  );
                },
                imageBuilder: (context, imageProvider) => Container(
                  width: widget.size!.width,
                  height: widget.size!.height,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    image: DecorationImage(
                        image: imageProvider, fit: BoxFit.cover),
                  ),
                ),
                width: widget.size!.width,
                height: widget.size!.height,
                httpHeaders: Hoster.header(url: widget.url),
              ));
  }
}
