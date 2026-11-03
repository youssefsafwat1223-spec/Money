import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/app_toast.dart';

void main() {
  for (final dark in [false, true]) {
    for (final error in [false, true]) {
      testWidgets('toast has an opaque readable surface over navy dark=$dark error=$error', (tester) async {
        late BuildContext context;
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: Builder(builder: (value) {
            context = value;
            return const Scaffold(backgroundColor: Color(0xFF0C1330));
          }),
        ));
        if (error) {
          AppToast.showError(context, 'Visible error message');
        } else {
          AppToast.show(context, 'Visible status message');
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final label = find.text(error ? 'Visible error message' : 'Visible status message');
        final surface = tester.widget<Container>(find.ancestor(of: label,
          matching: find.byWidgetPredicate((widget) => widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color != null)).first);
        final background = (surface.decoration! as BoxDecoration).color!;
        final foreground = tester.widget<Text>(label).style!.color!;
        expect(background.a, 1);
        final first = foreground.computeLuminance();
        final second = background.computeLuminance();
        final contrast = ((first > second ? first : second) + .05) /
            ((first > second ? second : first) + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
