import 'package:flutter/material.dart';

/// 统一的回顶按钮组件
/// 提供一致的出现/消失动画（缩放 + 淡入淡出）
class BackToTopButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onPressed;
  final String heroTag;
  final double bottom;

  const BackToTopButton({
    super.key,
    required this.visible,
    required this.onPressed,
    required this.heroTag,
    this.bottom = 80,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: bottom,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: AnimatedOpacity(
            opacity: visible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: FloatingActionButton.small(
              heroTag: heroTag,
              onPressed: visible ? onPressed : null,
              child: const Icon(Icons.keyboard_arrow_up),
            ),
          ),
        ),
      ),
    );
  }
}

/// 基于 ValueNotifier 的回顶按钮包装
/// 适用于 LightingList、PainterList 等使用 ValueNotifier<bool> 的场景
class ValueListenableBackToTopButton extends StatelessWidget {
  final ValueNotifier<bool> notifier;
  final VoidCallback onPressed;
  final String heroTag;
  final double bottom;

  const ValueListenableBackToTopButton({
    super.key,
    required this.notifier,
    required this.onPressed,
    required this.heroTag,
    this.bottom = 80,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (_, visible, __) {
        return BackToTopButton(
          visible: visible,
          onPressed: onPressed,
          heroTag: heroTag,
          bottom: bottom,
        );
      },
    );
  }
}
