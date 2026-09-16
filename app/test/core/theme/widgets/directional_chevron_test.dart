import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/widgets/directional_chevron.dart';

/// The disclosure chevron must point the way the reader travels.
///
/// Found by running the app in `en` on a Simulator: the containers mirrored
/// correctly, and the glyph did not. A `Directionality.of(context)` assertion
/// passes straight over that — the direction was right, the picture was wrong.
///
/// The trap this guards is subtler than the bug. `IconData(...,
/// matchTextDirection: true)` looks like the fix and is backwards: Flutter
/// mirrors a matching icon **only in RTL** (`widgets/icon.dart:334-344`), so
/// the bundled LEFT-chevron glyph would point left in LTR and right in RTL —
/// wrong both ways. These tests assert the transform itself, so a future
/// "simplification" to `matchTextDirection` fails here instead of shipping.
void main() {
  Future<void> pumpIn(WidgetTester tester, TextDirection direction) {
    return tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: const Center(child: DirectionalChevron(size: 20)),
      ),
    );
  }

  /// The horizontal scale the widget applies; 1.0 means "not mirrored".
  double horizontalScale(WidgetTester tester) {
    final transforms = tester.widgetList<Transform>(find.byType(Transform));
    if (transforms.isEmpty) return 1.0;
    return transforms.first.transform.storage[0];
  }

  testWidgets('RTL keeps the bundled left-chevron unmirrored — it already '
      'points forward in Arabic', (tester) async {
    await pumpIn(tester, TextDirection.rtl);
    expect(horizontalScale(tester), 1.0);
  });

  testWidgets('LTR mirrors it, so it points right', (tester) async {
    await pumpIn(tester, TextDirection.ltr);
    expect(horizontalScale(tester), -1.0,
        reason: 'in English the disclosure chevron must point right; an '
            'unmirrored left chevron is the defect this widget exists for');
  });

  testWidgets('the two directions do not render identically', (tester) async {
    await pumpIn(tester, TextDirection.rtl);
    final rtl = horizontalScale(tester);
    await pumpIn(tester, TextDirection.ltr);
    final ltr = horizontalScale(tester);
    expect(rtl == ltr, isFalse,
        reason: 'if both directions render the same, the widget has stopped '
            'being directional and the LTR defect is back');
  });
}
