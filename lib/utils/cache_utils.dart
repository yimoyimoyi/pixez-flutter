import 'dart:io';

/// 缓存管理公共工具

/// 在 isolate 中复制缓存目录（避免大缓存下主 isolate 卡顿）。
/// 返回复制的文件数。
int copyCacheDirectoryTo(({String src, String dest}) paths) {
  final srcDir = Directory(paths.src);
  final destDir = Directory(paths.dest);
  if (destDir.existsSync()) destDir.deleteSync(recursive: true);
  destDir.createSync(recursive: true);
  int copied = 0;
  for (final entity in srcDir.listSync(recursive: true)) {
    if (entity is File) {
      final relPath = entity.path.substring(srcDir.path.length + 1);
      final destFile = File('${destDir.path}/$relPath');
      destFile.parent.createSync(recursive: true);
      entity.copySync(destFile.path);
      copied++;
    }
  }
  return copied;
}
