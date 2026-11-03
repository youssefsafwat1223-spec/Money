import 'package:flutter/material.dart';

import '../app_colors.dart';
import 'mali_glass.dart';

/// A [ScaffoldMessenger] whose snackbars sit on the Liquid Glass material.
///
/// Placed once at the app root (inside MaterialApp's own messenger), so every
/// `ScaffoldMessenger.of(context).showSnackBar(SnackBar(...))` in the app —
/// unchanged call sites — renders as a floating glass pill instead of the
/// opaque Material bar no theme can make translucent-with-blur.
class GlassScaffoldMessenger extends ScaffoldMessenger {
  const GlassScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _GlassScaffoldMessengerState();
}

class _GlassScaffoldMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    return super.showSnackBar(
      SnackBar(
        key: snackBar.key,
        content: _GlassSnackContent(
          action: snackBar.action,
          child: snackBar.content,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        margin: snackBar.margin,
        width: snackBar.width,
        duration: snackBar.duration,
        onVisible: snackBar.onVisible,
        dismissDirection: snackBar.dismissDirection,
        persist: snackBar.persist,
        clipBehavior: Clip.none,
      ),
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
  }
}

class _GlassSnackContent extends StatelessWidget {
  const _GlassSnackContent({required this.child, this.action});

  final Widget child;
  final SnackBarAction? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliGlass(
      variant: MaliGlassVariant.pill,
      radius: 22,
      padding: EdgeInsets.zero,
      nativeMaterial: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(22),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: c.textPrimary),
          child: Row(
            children: [
              Expanded(child: child),
              if (action != null) action!,
            ],
          ),
        ),
      ),
    );
  }
}
