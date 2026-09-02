import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/models/am_article_block.dart';
import 'package:pixez/page/soup/soup_store.dart';

/// 真实 pixivision HTML fixture(2026-09-02 经源站 IP 直连抓取,裁剪保留 body):
/// - home_collection:首页合集(1 张 _article-eyecatch-card 头条 + 19 张 _article-card,
///   其中 1 张为专访卡,应全部放行)
/// - column_collection / novels_collection:文字类栏目列表(卡片全部放行)
/// - column_article:咖喱泽薰创作咨询(纯文字正文,无 .am__work → 文章块模式)
/// - interview_article:专访(问答块 + 内嵌作品 → 文章块模式)
/// - illust_article:视觉特辑(14 幅 .am__work → 作品流模式)
String fixture(String name) =>
    File('test/fixtures/soup/$name.html').readAsStringSync();

void main() {
  group('SoupStore 真实 pixivision HTML 解析', () {
    late SoupStore store;

    setUp(() {
      store = SoupStore();
    });

    test('首页合集:eyecatch 头条卡纳入解析,全部卡片放行(含专访卡)', () {
      store.testParseHtml(fixture('home_collection'));
      expect(store.amArticles.length, 21, reason: '20 普通卡 + 1 头条 eyecatch');
      expect(store.isCollection, true);
      expect(store.amWorks.isEmpty, true);
      expect(store.articleBlocks.isEmpty, true);

      // 第一张为首页头条(eyecatch 卡,此前版本漏抓)
      final first = store.amArticles.first;
      expect(first.id, '11660');
      expect(first.title, contains('甜蜜蜜的世界'));
      expect(first.category, '插画');

      // 专访卡(12013)不再被过滤
      final hasInterview = store.amArticles.any((c) => c.id == '12013');
      expect(hasInterview, true, reason: '专访卡应放行');
    });

    test('文字栏目页(专栏/小说):全部卡片放行而非整页误报文字专栏', () {
      store.testParseHtml(fixture('column_collection'));
      expect(store.amArticles.length, 20);
      expect(store.errorMessage, isNull);
      expect(store.amArticles.every((c) => c.category == '专栏'), true);

      store.testParseHtml(fixture('novels_collection'));
      expect(store.amArticles.length, 4);
      expect(store.errorMessage, isNull);
      expect(store.amArticles.every((c) => c.category == '小说'), true);
    });

    test('纯文字咨询专栏正文:走文章块模式并提取标题/分类/日期', () {
      store.testParseHtml(fixture('column_article'));
      expect(store.articleBlocks.isNotEmpty, true);
      expect(store.amWorks.isEmpty, true);
      expect(store.amArticles.isEmpty, true);
      expect(store.errorMessage, isNull);

      expect(store.articleTitle, contains('咖喱泽薰的创作咨询'));
      expect(store.articleCategory, '专栏');
      expect(store.articleDate, '2026.08.11');

      // 块类型覆盖:标题/段落/图片/署名
      final types = store.articleBlocks.map((b) => b.type).toSet();
      expect(types, contains(AmArticleBlockType.heading));
      expect(types, contains(AmArticleBlockType.paragraph));
      expect(types, contains(AmArticleBlockType.image));
      expect(types, contains(AmArticleBlockType.credit));

      // 段落文本应为纯文本(<br> 保留换行,无 HTML 标签)
      final firstPara = store.articleBlocks
          .firstWhere((b) => b.type == AmArticleBlockType.paragraph);
      expect(firstPara.text.contains('<'), false);
      expect(firstPara.text, isNotEmpty);
      // 多 <p> 段落不应粘连(块级间插空行),且保留原文文字
      final paras =
          store.articleBlocks.where((b) => b.type == AmArticleBlockType.paragraph);
      expect(paras.any((b) => b.text.contains('\n\n')), true,
          reason: '多段正文应以空行分隔');
      expect(
        store.articleBlocks
            .expand((b) => b.text.split('\n'))
            .any((s) => s.contains('咖喱泽老师您好')),
        true,
      );

      // 富文本:段落中的 <a> 链接解析为可点击片段(亚马逊购书链接)
      final allSpans =
          store.articleBlocks.expand((b) => b.spans).toList();
      expect(
        allSpans.any((s) =>
            s.link != null && s.link!.contains('amzn.asia') &&
            s.text.contains('amazon')),
        true,
        reason: '正文链接应解析为链接片段',
      );
      // 加粗片段保留(<b>)
      expect(allSpans.any((s) => s.bold && s.text.trim().isNotEmpty), true,
          reason: '<b> 加粗应解析为 bold 片段');
      // 图片块带 imgaz URL
      final img = store.articleBlocks
          .firstWhere((b) => b.type == AmArticleBlockType.image);
      expect(img.imageUrl, contains('i.pximg.net'));
    });

    test('专访正文:问答块与内嵌作品都进入文章块模式', () {
      store.testParseHtml(fixture('interview_article'));
      expect(store.articleBlocks.isNotEmpty, true);
      expect(store.amWorks.isEmpty, true, reason: '作品流模式不应启用');

      final types = store.articleBlocks.map((b) => b.type).toSet();
      expect(types, contains(AmArticleBlockType.question));
      expect(types, contains(AmArticleBlockType.answer));
      expect(types, contains(AmArticleBlockType.pixivIllust));

      final illustBlocks = store.articleBlocks
          .where((b) => b.type == AmArticleBlockType.pixivIllust)
          .toList();
      expect(illustBlocks.length, 10);
      expect(illustBlocks.first.work, isNotNull);
      expect(illustBlocks.first.imageUrl, contains('pximg.net'));

      final q = store.articleBlocks
          .firstWhere((b) => b.type == AmArticleBlockType.question);
      expect(q.text, contains('创作'));

      final a = store.articleBlocks
          .firstWhere((b) => b.type == AmArticleBlockType.answer);
      expect(a.text, isNotEmpty);

      // 专访回答中的 YouTube 链接与加粗强调
      final allSpans = store.articleBlocks.expand((b) => b.spans).toList();
      expect(
        allSpans.any((s) =>
            s.link != null && s.link!.contains('youtube.com')),
        true,
        reason: '回答内 YouTube 链接应解析',
      );
      expect(allSpans.any((s) => s.bold), true,
          reason: '回答内加粗应解析');
    });

    test('视觉特辑正文:14 幅作品走既有作品流模式', () {
      store.testParseHtml(fixture('illust_article'));
      expect(store.amWorks.length, 14);
      expect(store.articleBlocks.isEmpty, true);
      expect(store.errorMessage, isNull);

      final first = store.amWorks.first;
      expect(first.arworkLink, contains('artworks'));
      expect(first.showImage, contains('pximg.net'));
    });

    test('视觉特辑页同样解析文章头部元信息(直达链接场景)', () {
      store.testParseHtml(fixture('illust_article'));
      expect(store.articleTitle, contains('甜蜜蜜的世界'));
      expect(store.articleCategory, '插画');
    });
  });
}
