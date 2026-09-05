/*
 * 翻译并发门闩测试：验证 maxConcurrency 确实限制在途数，
 * 且 >1 时并发发生（防"信号量形同虚设/并行无效"回归）。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:pixez/translation/translation_queue.dart';

void main() {
  test('isSameResultFailure：日文未翻判失败，品牌名/中文保留合法', () {
    // 中文目标：含假名的日文原文被原样返回 → 失败
    expect(isSameResultFailure('こんにちは', 'こんにちは', 'zh-CN'), true);
    // 中文目标：品牌名原样返回 → 保留合法
    expect(isSameResultFailure('【Fantia】', '【Fantia】', 'zh-CN'), false);
    expect(isSameResultFailure('Patreon', 'Patreon', 'zh-CN'), false);
    // 中文目标：纯中文内容原样 → 保留合法（本就是目标语言）
    expect(isSameResultFailure('纯中文说明', '纯中文说明', 'zh-CN'), false);
    // 非中文目标宽松：一律不判失败
    expect(isSameResultFailure('こんにちは', 'こんにちは', 'en-US'), false);
    // 有差异即成功
    expect(isSameResultFailure('こんにちは', '你好', 'zh-CN'), false);
  });

  test('limit=1 严格串行（峰值 1）', () async {
    final gate = ConcurrencyGate(limit: 1);
    var peak = 0;
    var running = 0;
    Future<void> task(int id) async {
      await gate.acquire();
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      running--;
      gate.release();
    }

    await Future.wait([for (var i = 0; i < 6; i++) task(i)]);
    expect(peak, 1);
  });

  test('limit=3 并发峰值恰好 3', () async {
    final gate = ConcurrencyGate(limit: 3);
    var peak = 0;
    var running = 0;
    Future<void> task(int id) async {
      await gate.acquire();
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      running--;
      gate.release();
    }

    await Future.wait([for (var i = 0; i < 9; i++) task(i)]);
    expect(peak, 3); // 至少 3（能并发）且不超 3（受限）
  });
}
