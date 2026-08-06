import 'package:fluent_ui/fluent_ui.dart';

class PixEzButton extends StatelessWidget {
  final Widget child;
  final void Function()? onPressed;
  final void Function()? onLongPress;
  final bool noPadding;
  final String? toolTips;
  final InlineSpan? richToolTips;

  const PixEzButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.noPadding = false,
    this.toolTips,
    this.richToolTips,
  });

  @override
  Widget build(BuildContext context) {
    Widget widget = child;
    widget = ClipRRect(
      borderRadius: const BorderRadius.all(const Radius.circular(4.0)),
      child: widget,
    );
    // 长按通过 GestureDetector 包装实现（IconButton 无 onLongPress）
    if (onLongPress != null) {
      widget = GestureDetector(onLongPress: onLongPress, child: widget);
    }
    widget = IconButton(icon: widget, onPressed: onPressed);
    widget = ButtonTheme(
      data: ButtonThemeData(
        iconButtonStyle: ButtonStyle(
          padding: WidgetStateProperty.all(EdgeInsets.zero),
        ),

        ),
      ),
      child: widget,
    );
    if (richToolTips != null) {
      widget = Tooltip(richMessage: richToolTips, child: widget);
    } else if (toolTips?.isNotEmpty == true) {
      widget = Tooltip(message: toolTips, child: widget);
    }

    return Padding(
      padding: noPadding ? EdgeInsets.zero : const EdgeInsets.all(4.0),
      child: widget,
    );
  }
}
