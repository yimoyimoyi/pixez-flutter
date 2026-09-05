/*
 * 翻译结果 MobX store：key(见 translate_engine.dart) -> 译文。
 * UI 通过 resultOf(key) 读取（Observer 自动追踪），译文就绪时自动重建显示。
 * 注意：译文一律经此 store 传递，绝不原地改写 widget 传入的模型对象。
 */

import 'package:mobx/mobx.dart';

part 'translation_store.g.dart';

class TranslationStore = _TranslationStoreBase with _$TranslationStore;

abstract class _TranslationStoreBase with Store {
  @observable
  Map<String, String> translated = {};

  /// 在途请求的 key（供 UI 显示翻译中状态）
  @observable
  Set<String> pending = {};

  bool has(String key) => translated.containsKey(key);

  String? resultOf(String key) => translated[key];

  @action
  void setResult(String key, String value) {
    if (value.isEmpty || translated[key] == value) return;
    translated = Map<String, String>.from(translated)..[key] = value;
  }

  @action
  void markPending(String key, bool value) {
    final next = Set<String>.from(pending);
    if (value) {
      next.add(key);
    } else {
      next.remove(key);
    }
    pending = next;
  }

  /// 启动 warmup：把磁盘缓存未过期条目整体载入内存
  @action
  void loadAll(Map<String, String> entries) {
    translated = Map<String, String>.from(entries);
  }

  @action
  void clear() {
    translated = {};
    pending = {};
  }
}
