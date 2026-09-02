/*
 * Copyright (C) 2026. by perol_notsf, All rights reserved
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

import 'amwork.dart';

/// pixivision 正文块类型(pixivision 正文由有序的
/// `article-item _feature-article-body__xxx` 块构成,2026-09 实测)
enum AmArticleBlockType {
  paragraph, // 正文段落
  heading, // 小节标题(h2/h3/h4)
  image, // 内嵌插图(imgaz)
  credit, // 署名(文／咖喱泽薰)
  caption, // 图片说明
  question, // 来信/提问(专栏、专访的 Q)
  answer, // 回答(专访的 A,正文在 .answer-text 内)
  pixivIllust, // pixiv 作品内嵌(块内含 .am__work)
  articleCard, // 文末关联特辑卡(._article-card)
}

/// 富文本行内片段(正文只出现 <b> 加粗与 <a> 链接,白名单解析)
class AmInlineSpan {
  final String text;
  final bool bold;
  final String? link;

  const AmInlineSpan({required this.text, this.bold = false, this.link});
}

/// pixivision 正文的一个有序内容块
class AmArticleBlock {
  final AmArticleBlockType type;
  /// 文本类块的纯文本(段落/标题/问答/署名…,富文本标签已剥离)
  final String text;
  /// 文本类块的富文本片段(段落/问答等;标题等简单文本块可为空)
  final List<AmInlineSpan> spans;
  /// image 块的插图地址 / pixivIllust 的作品图 / articleCard 缩略图
  final String imageUrl;
  /// 块携带的跳转地址(pixivIllust 的原作品页 / articleCard 的特辑页)
  final String linkUrl;
  /// pixivIllust 块解析出的作品(供点击原图/详情跳转)
  final AmWork? work;

  AmArticleBlock({
    required this.type,
    this.text = '',
    this.spans = const [],
    this.imageUrl = '',
    this.linkUrl = '',
    this.work,
  });
}
