import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' show parse;
import 'package:pixez/page/soup/soup_store.dart';

void main() {
  group('SoupStore 特辑合集与文字特辑过滤测试', () {
    late SoupStore store;

    setUp(() {
      store = SoupStore();
    });

    test('文字分类识别 testIsTextCategory 准确过滤各类文字标签', () {
      // 应识别为文字特辑分类
      expect(store.testIsTextCategory('专栏'), true);
      expect(store.testIsTextCategory('column'), true);
      expect(store.testIsTextCategory('コラム'), true);
      expect(store.testIsTextCategory('新闻'), true);
      expect(store.testIsTextCategory('news'), true);
      expect(store.testIsTextCategory('ニュース'), true);
      expect(store.testIsTextCategory('小说'), true);
      expect(store.testIsTextCategory('novel'), true);
      expect(store.testIsTextCategory('inspiration'), true);
      expect(store.testIsTextCategory('arc__thumbnail-label _category-label large inspiration'), true);

      // 视觉类特辑分类应被保留（非文字特辑）
      expect(store.testIsTextCategory('插画'), false);
      expect(store.testIsTextCategory('illustration'), false);
      expect(store.testIsTextCategory('manga'), false);
      expect(store.testIsTextCategory('マンガ'), false);
      expect(store.testIsTextCategory('spotlight'), false);
    });

    test('合集页面卡片解析：准确保留插画特辑卡片，直接过滤文字专栏卡片', () {
      const html = '''
      <div class="_feature-article-body">
        <!-- 1. 文字专栏卡片（应被直接过滤） -->
        <article class="_article-card inspiration">
          <div class="arc__thumbnail-container">
            <a href="/zh/a/11717">
              <div class="_thumbnail" style="background-image: url(https://i.pximg.net/imgaz/upload/column1.png)"></div>
            </a>
            <a href="/zh/c/column">
              <span class="arc__thumbnail-label _category-label large inspiration">专栏</span>
            </a>
          </div>
          <div class="arc__title-container">
            <h2 class="arc__title">
              <a href="/zh/a/11717">年过30的阿宅／咖喱泽薰的创作咨询</a>
            </h2>
          </div>
          <div class="arc__footer-container">
            <time class="_date small light-gray" datetime="2026-05-08">2026.05.08</time>
          </div>
        </article>

        <!-- 2. 插画特辑卡片（应被保留） -->
        <article class="_article-card spotlight">
          <div class="arc__thumbnail-container">
            <a href="/zh/a/11796">
              <div class="_thumbnail" style="background-image: url(https://i.pximg.net/imgaz/upload/illust1.png)"></div>
            </a>
            <a href="/zh/c/illustration">
              <span class="arc__thumbnail-label _category-label large spotlight">插画</span>
            </a>
          </div>
          <div class="arc__title-container">
            <h2 class="arc__title">
              <a href="/zh/a/11796">夏天与美少女插画特辑</a>
            </h2>
          </div>
          <div class="arc__footer-container">
            <time class="_date small light-gray" datetime="2026-06-01">2026.06.01</time>
          </div>
        </article>

        <!-- 3. 新闻类文字卡片（应被过滤） -->
        <article class="_article-card inspiration">
          <div class="arc__thumbnail-container">
            <a href="/zh/a/11950">
              <div class="_thumbnail" style="background-image: url(https://i.pximg.net/imgaz/upload/news1.png)"></div>
            </a>
            <a href="/zh/c/news">
              <span class="arc__thumbnail-label _category-label large inspiration">ニュース</span>
            </a>
          </div>
          <div class="arc__title-container">
            <h2 class="arc__title">
              <a href="/zh/a/11950">新功能上线公告</a>
            </h2>
          </div>
        </article>

        <!-- 4. 漫画特辑卡片（应被保留） -->
        <article class="_article-card spotlight">
          <div class="arc__thumbnail-container">
            <a href="/zh/a/11800">
              <div class="_thumbnail" style="background-image: url(https://i.pximg.net/imgaz/upload/manga1.png)"></div>
            </a>
            <a href="/zh/c/manga">
              <span class="arc__thumbnail-label _category-label large spotlight">漫画</span>
            </a>
          </div>
          <div class="arc__title-container">
            <h2 class="arc__title">
              <a href="/zh/a/11800">搞笑短篇漫画特辑</a>
            </h2>
          </div>
          <div class="arc__footer-container">
            <time class="_date small light-gray" datetime="2026-06-15">2026.06.15</time>
          </div>
        </article>
      </div>
      ''';

      final doc = parse(html);
      final cards = doc.querySelectorAll('._article-card');
      expect(cards.length, 4);

      for (var card in cards) {
        store.testParseArticleCard(card);
      }

      // 验证：4 张卡片中，两张文字类（专栏、新闻）被过滤，只保留两张视觉类（插画、漫画）
      expect(store.amArticles.length, 2);
      expect(store.isCollection, true);

      // 第一张：插画特辑
      final illustCard = store.amArticles[0];
      expect(illustCard.id, '11796');
      expect(illustCard.title, '夏天与美少女插画特辑');
      expect(illustCard.category, '插画');
      expect(illustCard.articleUrl, 'https://www.pixivision.net/zh/a/11796');
      expect(illustCard.thumbnail, 'https://i.pximg.net/imgaz/upload/illust1.png');
      expect(illustCard.date, '2026.06.01');

      // 第二张：漫画特辑
      final mangaCard = store.amArticles[1];
      expect(mangaCard.id, '11800');
      expect(mangaCard.title, '搞笑短篇漫画特辑');
      expect(mangaCard.category, '漫画');
      expect(mangaCard.articleUrl, 'https://www.pixivision.net/zh/a/11800');
      expect(mangaCard.thumbnail, 'https://i.pximg.net/imgaz/upload/manga1.png');
      expect(mangaCard.date, '2026.06.15');
    });

    test('初始化状态验证', () {
      expect(store.isCollection, false);
      expect(store.isTextArticle, false);
      expect(store.amArticles.isEmpty, true);
      expect(store.amWorks.isEmpty, true);
    });
  });
}
