/*
 * 翻译结果缓存：sqflite 持久层 + 内存 LRU 双层。
 * 内存层承载"列表卡片只读缓存"：启动 warmup 后卡片同步读内存，零网络、零磁盘 IO。
 * key 由翻译原文 hash + 引擎 + 目标语言 构成（见 translate_engine.dart）。
 */

import 'dart:collection';

import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TranslationCacheEntry {
  final String key;
  final String value;
  final int expireTime;
  final int dateTime;

  const TranslationCacheEntry({
    required this.key,
    required this.value,
    required this.expireTime,
    required this.dateTime,
  });

  bool get isExpired => expireTime > 0 && DateTime.now().millisecondsSinceEpoch > expireTime;

  Map<String, Object> toMap() => {
        'key': key,
        'value': value,
        'expire_time': expireTime,
        'date_time': dateTime,
      };

  factory TranslationCacheEntry.fromMap(Map<String, Object?> map) {
    return TranslationCacheEntry(
      key: map['key'] as String,
      value: map['value'] as String? ?? '',
      expireTime: map['expire_time'] as int? ?? 0,
      dateTime: map['date_time'] as int? ?? 0,
    );
  }
}

/// sqflite 持久层（参考 lib/models/key_value_pair.dart 的 KVProvider 模式）
class TranslationCacheProvider {
  static const String _table = 'translation_cache';
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, 'translation.db');
    _db = await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
create table $_table (
  key text primary key,
  value text not null,
  expire_time integer not null,
  date_time integer not null
  )
''');
    });
    // 清理旧 key 版本（v1 无"译文==原文视为失败"校验，可能含错误结果污染）
    try {
      await _db!.delete(_table, where: "key LIKE 'v1|%'");
    } catch (_) {}
    return _db!;
  }

  Future<void> insert(TranslationCacheEntry entry) async {
    final db = await _open();
    await db.insert(_table, entry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<TranslationCacheEntry?> get(String key) async {
    final db = await _open();
    final maps = await db.query(_table,
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (maps.isEmpty) return null;
    return TranslationCacheEntry.fromMap(maps.first);
  }

  /// 读出全部未过期条目（用于启动 warmup）
  Future<List<TranslationCacheEntry>> getAllNotExpired() async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final maps = await db.query(_table,
        where: 'expire_time = 0 OR expire_time > ?', whereArgs: [now]);
    return maps.map(TranslationCacheEntry.fromMap).toList();
  }

  Future<void> deleteExpired() async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.delete(_table, where: 'expire_time > 0 AND expire_time <= ?', whereArgs: [now]);
  }
}

/// 内存 LRU 缓存：按访问顺序淘汰，限定容量防止列表热数据挤爆内存
class TranslationMemoryCache {
  TranslationMemoryCache({this.maxEntries = 5000});

  final int maxEntries;
  final LinkedHashMap<String, String> _map = LinkedHashMap();

  String? get(String key) {
    final value = _map[key];
    if (value != null && !value.isEmpty) {
      // 移到底部代表最近访问
      _map.remove(key);
      _map[key] = value;
    }
    return value;
  }

  bool has(String key) => _map.containsKey(key);

  void set(String key, String value) {
    if (_map.containsKey(key)) _map.remove(key);
    _map[key] = value;
    while (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  void loadAll(Map<String, String> entries) {
    for (final e in entries.entries) {
      _map[e.key] = e.value;
    }
  }

  void clear() => _map.clear();
}
