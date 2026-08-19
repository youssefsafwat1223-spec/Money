import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'calm_canvas.dart';

/// MaliScreen — the flagship black canvas (docs/MALI_DESIGN_SYSTEM.md).
///
/// Paints its own explicit black background + a restrained top-of-screen
/// glow, independent of the ambient `Theme.of(context)` (the app's only
/// wired `ThemeData` today is the light theme — see design doc §0). Hosts
/// content in a scroll view when [slivers] is given, or a plain [child]
/// otherwise.
///
/// P1 note: this is the static shell only. Scroll-linked parallax on the
/// hero is planned motion work (design doc phase P4) and is intentionally
/// not implemented here.
class MaliScreen extends StatelessWidget {
  const MaliScreen({
    super.key,
    this.child,
    this.slivers,
    this.padding = const EdgeInsets.symmetric(horizontal: 24),
    this.safeArea = true,
    this.ambient = true,
  }) : assert(
          (child == null) != (slivers == null),
          'Provide exactly one of child or slivers.',
        );

  /// Simple non-scrolling content mode.
  final Widget? child;

  /// Scrolling content mode — passed straight to a [CustomScrollView].
  final List<Widget>? slivers;

  final EdgeInsetsGeometry padding;

  /// Wrap content in a [SafeArea]. Set false when the screen deliberately
  /// paints under the status bar (e.g. the Home header).
  final bool safeArea;

  /// Pass-through to [CalmCanvas.ambient] — `false` drops the blue top glow
  /// and the two aurora blobs behind the content.
  final bool ambient;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    // CalmCanvas paints the combined background (canvas + top glow + aurora
    // blobs + grain), tuned from MaliTokens. Material (transparent) gives
    // descendants a Material ancestor for InkWell/Tooltip etc., and the
    // explicit DefaultTextStyle replaces Flutter's fallback style — without it,
    // every Text on this canvas inherits the debug "no DefaultTextStyle" yellow
    // double-underline (production screens avoid this via Scaffold's Material;
    // MaliScreen paints its own canvas and must provide it itself).
    return CalmCanvas(
      ambient: ambient,
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: AppTypography.body(t.textOnCanvasPrimary),
          child: _MaybeSafeArea(
            enabled: safeArea,
            child: Padding(
              padding: padding,
              child:
                  slivers != null ? CustomScrollView(slivers: slivers!) : child,
            ),
          ),
        ),
      ),
    );
  }
}

class _MaybeSafeArea extends StatelessWidget {
  const _MaybeSafeArea({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      enabled ? SafeArea(child: child) : child;
}
