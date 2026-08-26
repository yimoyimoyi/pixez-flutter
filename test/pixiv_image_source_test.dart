import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/network/network_mode.dart';

void main() {
  group('PixivImageSource.resolveUri — 自定义图床 URL 改写', () {
    const source = 'p.yimovpn.xyz';
    final uri = Uri.parse(
        'https://i.pximg.net/img-master/img/2024/07/13/21/40/50/120498462_p0_master1200.jpg');

    test('自定义图床：i.pximg.net 改写为 图床host/原始host/路径', () {
      final resolved = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(
        resolved.toString(),
        'https://p.yimovpn.xyz/i.pximg.net/img-master/img/2024/07/13/21/40/50/120498462_p0_master1200.jpg',
      );
    });

    test('默认图床（i.pximg.net）：不改写', () {
      final resolved = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: PixivImageSource.imageHost,
      );
      expect(resolved.toString(), uri.toString());
    });

    test('pictureSource 为空：不改写', () {
      final resolved = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: null,
      );
      expect(resolved.toString(), uri.toString());
    });

    test('已改写的 URL 幂等：再次 resolve 不再变化', () {
      // 与缓存 key 一致性相关：改写后 URL 经 Dio 拦截器再次处理必须保持原样
      final once = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      final twice = PixivImageSource.resolveUri(
        once,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(twice.toString(), once.toString());
    });

    test('s.pximg.net 同样改写', () {
      final sUri = Uri.parse(
          'https://s.pximg.net/c/250x250_80_a2/img-master/img/2024/07/13/21/40/50/120498462_p0_square1200.jpg');
      final resolved = PixivImageSource.resolveUri(
        sUri,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(
        resolved.toString(),
        'https://p.yimovpn.xyz/s.pximg.net/c/250x250_80_a2/img-master/img/2024/07/13/21/40/50/120498462_p0_square1200.jpg',
      );
    });

    test('pixivision CDN（*.pximg.net）改写', () {
      final embedUri = Uri.parse('https://embed.pximg.net/img/2024/01/01/00/00/00/x.jpg');
      final resolved = PixivImageSource.resolveUri(
        embedUri,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(resolved.host, 'p.yimovpn.xyz');
      expect(resolved.path, '/embed.pximg.net/img/2024/01/01/00/00/00/x.jpg');
    });

    test('API 域名不改写（非图片域）', () {
      final apiUri = Uri.parse('https://app-api.pixiv.net/v2/illust/detail');
      final resolved = PixivImageSource.resolveUri(
        apiUri,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(resolved.toString(), apiUri.toString());
    });

    test('图床 URL 带协议（https://host）', () {
      final resolved = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: 'https://p.yimovpn.xyz',
      );
      expect(
        resolved.toString(),
        'https://p.yimovpn.xyz/i.pximg.net/img-master/img/2024/07/13/21/40/50/120498462_p0_master1200.jpg',
      );
    });

    test('图床 URL 带子路径前缀（https://host/proxy/）', () {
      final resolved = PixivImageSource.resolveUri(
        uri,
        networkMode: NetworkMode.standard,
        pictureSource: 'https://p.yimovpn.xyz/proxy/',
      );
      expect(
        resolved.toString(),
        'https://p.yimovpn.xyz/proxy/i.pximg.net/img-master/img/2024/07/13/21/40/50/120498462_p0_master1200.jpg',
      );
    });

    test('保留原始 query 参数', () {
      final withQuery = Uri.parse('https://i.pximg.net/img/a.jpg?foo=1&bar=2');
      final resolved = PixivImageSource.resolveUri(
        withQuery,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(resolved.host, 'p.yimovpn.xyz');
      expect(resolved.query, 'foo=1&bar=2');
      expect(resolved.path, '/i.pximg.net/img/a.jpg');
    });
  });

  group('PixivImageSource.resolvePixivUrl — 登录/API URL', () {
    const source = 'p.yimovpn.xyz';
    final url = 'https://app-api.pixiv.net/v2/illust/detail?id=1';

    test('standard 模式不改写（与 resolveUri 策略不同）', () {
      final resolved = PixivImageSource.resolvePixivUrl(
        url,
        networkMode: NetworkMode.standard,
        pictureSource: source,
      );
      expect(resolved, url);
    });

    test('compat 模式改写', () {
      final resolved = PixivImageSource.resolvePixivUrl(
        url,
        networkMode: NetworkMode.compat,
        pictureSource: source,
      );
      expect(resolved, 'https://p.yimovpn.xyz/app-api.pixiv.net/v2/illust/detail?id=1');
    });
  });
}
