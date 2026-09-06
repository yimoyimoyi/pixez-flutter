/*
 * 翻译结果 MobX store：key(见 translate_engine.dart) -> 译文。
 * UI 通过 resultOf(key) 读取（Observer 自动追踪），译文就绪时自动重建显示。
 * 注意：译文一律经此 store 传递，绝不原地改写 widget 传入的模型对象。
 */

import 'package:mobx/mobx.dart';

part 'translation_store.g.dart';

class TranslationStore = _TranslationStoreBase with _$TranslationStore;

abstract class _TranslationStoreBase with Store {
  static const int maxStoreEntries = 5000;

  @observable
  ObservableMap<String, String> translated = ObservableMap<String, String>();

  /// 在途请求的 key（供 UI 显示翻译中状态）
  @observable
  ObservableSet<String> pending = ObservableSet<String>();

  bool has(String key) => translated.containsKey(key);

  String? resultOf(String key) => translated[key];

  @action
  void setResult(String key, String value) {
    if (value.isEmpty || translated[key] == value) return;
    translated[key] = value;
    while (translated.length > maxStoreEntries) {
      translated.remove(translated.keys.first);
    }
  }

  @action
  void markPending(String key, bool value) {
    if (value) {
      pending.add(key);
    } else {
      pending.remove(key);
    }
  }

  /// 启动 warmup：把磁盘缓存未过期条目整体载入内存
  @action
  void loadAll(Map<String, String> entries) {
    translated.clear();
    translated.addAll(entries);
    while (translated.length > maxStoreEntries) {
      translated.remove(translated.keys.first);
    }
  }

  @action
  void clear() {
    translated.clear();
    pending.clear();
  }
}
