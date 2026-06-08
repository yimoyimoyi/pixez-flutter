import 'lib/er/pixiv_image_source.dart';

void main() {
  final tests = [
    'https://embed.pixiv.net/pixivision/zh/a/11639/ogimage.jpg',
    'https://i.pximg.net/img-original/img/2024/01/12345678_p0.jpg',
    'https://i.pximg.net/c/600x1200/img-master/img/2024/01/12345678_p0_master1200.jpg',
    'https://www.pixivision.net/images/header.png',
  ];

  for (var url in tests) {
    final uri = Uri.parse(url);
    print('IN:  $url');
    print('  host: ${uri.host}');
    print('  match: ${PixivImageSource._isPixivImageHost(uri.host)}');

    // 模拟重写
    final rewritten = PixivImageSource.resolveUri(
      uri,
      networkMode: NetworkMode.compat,
      pictureSource: 'pixez.example.com',
    );
    print('  rewritten: $rewritten');
    print('');
  }
}
