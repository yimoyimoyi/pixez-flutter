// 临时脚本：计算 sqlite3 native assets 的下载缓存目录名
// 运行: dart run _calc_hash.dart

void main() {
  const releaseTag = 'sqlite3-3.1.6';

  // Architecture 名称（对应 code_assets 包的 Architecture 枚举值）
  // 注意：这里用实际构建中使用的名称
  final configs = [
    ('arm', 'arm.android'),
    ('arm64', 'arm64.android'),
    ('x64', 'x64.android'),
  ];

  // TargetOperatingSystem.android 的 name 为 'android'
  const osName = 'android';

  for (final (arch, label) in configs) {
    final hashCode = Object.hash(
      osName,
      arch,
      'sqlite3', // LibraryType.sqlite3
      releaseTag,
    );
    final dirname = 'download-${hashCode.toRadixString(16)}';
    print('$label → $dirname → libsqlite3.so');
  }
}
