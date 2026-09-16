import 'package:flutter/widgets.dart';

import '../../utils/app_lucide_icons.dart';

/// The disclosure ("go forward") chevron, pointing the way the reader travels.
///
/// ## Why this is a widget and not an `IconData`
///
/// Fifteen list rows, cards and sheet fields used `AppLucideIcons.chevronLeft`
/// directly. That is correct in Arabic, where forward is leftward, and wrong in
/// English — a bilingual Simulator walk showed the containers mirroring
/// correctly under `en` while the glyph kept pointing left, which is exactly
/// the kind of defect a `Directionality.of(context)` assertion passes over:
/// the direction was right, the picture was not.
///
/// The obvious fix — `IconData(..., matchTextDirection: true)` — is backwards
/// here, and quietly so. Flutter mirrors a matching icon **only in RTL**
/// (`icon.dart:334-344`): with the LEFT-chevron glyph that yields left in LTR
/// and right in RTL, which is wrong in both. The icon set bundles
/// chevron-down, chevron-left and chevron-up but no chevron-right, so there is
/// no glyph to swap to. Mirroring explicitly in LTR is the honest way to get
/// it right without guessing a codepoint.
class DirectionalChevron extends StatelessWidget {
  const DirectionalChevron({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(AppLucideIcons.chevronLeft, size: size, color: color);
    // RTL reads right-to-left, so the bundled left-chevron already points
    // forward; LTR needs it flipped.
    return switch (Directionality.of(context)) {
      TextDirection.rtl => icon,
      TextDirection.ltr => Transform(
          transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1),
          alignment: Alignment.center,
          transformHitTests: false,
          child: icon,
        ),
    };
  }
}
