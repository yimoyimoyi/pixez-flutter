import 'package:fluent_ui/fluent_ui.dart';

class PixEzButton extends StatelessWidget {
  final Widget child;
  final void Function()? onPressed;
  final void Function()? onLongPress;
  final bool noPadding;

  const PixEzButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.noPadding = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: noPadding ? EdgeInsets.zero : const EdgeInsets.all(4.0),
        child: GestureDetector(
          onTap: onPressed,
          onLongPress: onLongPress,
          child: ButtonTheme(
            data: ButtonThemeData(
              iconButtonStyle: ButtonStyle(
                padding: WidgetStateProperty.all(EdgeInsets.zero),
              ),
            ),
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.all(const Radius.circular(4.0)),
              child: child,
            ),
          ),
        ),
      );
}
