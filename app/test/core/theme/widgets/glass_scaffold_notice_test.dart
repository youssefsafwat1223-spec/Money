import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_scaffold_messenger.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('root notice stays readable across scaffold replacement and preserves its action dark=$dark', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final version = ValueNotifier<int>(0);
      addTearDown(version.dispose);
      var visibleCalls = 0;
      var actionCalls = 0;
      await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.dark : AppTheme.light,
        home: GlassScaffoldMessenger(key: messenger,
          child: ValueListenableBuilder<int>(valueListenable: version,
            builder: (context, value, _) => Scaffold(key: ValueKey(value),
              backgroundColor: const Color(0xFF0C1330), body: Text('Screen $value')))),
      ));
      final controller = messenger.currentState!.showSnackBar(SnackBar(
        content: const Text('Synthetic queued root notice'),
        onVisible: () => visibleCalls++,
        action: SnackBarAction(label: 'Review', onPressed: () => actionCalls++),
      ));
      await tester.pumpAndSettle();
      version.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('Screen 1'), findsOneWidget);
      final label = find.text('Synthetic queued root notice');
      expect(label, findsOneWidget);
      final surface = tester.widget<Container>(find.ancestor(of: label,
        matching: find.byWidgetPredicate((widget) => widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color != null)).first);
      final background = (surface.decoration! as BoxDecoration).color!;
      final foreground = DefaultTextStyle.of(tester.element(label)).style.color!;
      expect(background.a, 1);
      final a = background.computeLuminance();
      final b = foreground.computeLuminance();
      expect(((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
          greaterThanOrEqualTo(4.5));
      expect(visibleCalls, 1);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(actionCalls, 1);
      expect(await controller.closed, SnackBarClosedReason.action);
      expect(tester.takeException(), isNull);
    });
  }
}
