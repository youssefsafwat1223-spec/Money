import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/app_toast.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';

void main() {
  testWidgets('captured root overlay shows an error after its nested screen is disposed',
      (tester) async {
    final root = GlobalKey<NavigatorState>();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    late BuildContext oldContext;
    late OverlayState overlay;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: root,
      theme: AppTheme.light,
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (context, show, _) => show
            ? Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(body: Builder(builder: (context) {
                  oldContext = context;
                  overlay = Overlay.of(context, rootOverlay: true);
                  return const Text('old nested screen');
                }))))
            : const Scaffold(body: Text('replacement screen')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(identical(overlay, root.currentState!.overlay), isTrue);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(oldContext.mounted, isFalse);
    expect(overlay.mounted, isTrue);

    AppToast.showErrorInOverlay(overlay, 'Captured failure');
    await tester.pumpAndSettle();
    expect(find.text('replacement screen'), findsOneWidget);
    expect(find.text('Captured failure'), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('a disposed overlay is ignored without replacing a current notice',
      (tester) async {
    late OverlayState disposedOverlay;
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light,
      home: Builder(builder: (context) {
        disposedOverlay = Overlay.of(context, rootOverlay: true);
        return const Scaffold();
      })));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposedOverlay.mounted, isFalse);

    late BuildContext currentContext;
    await tester.pumpWidget(MaterialApp(theme: AppTheme.dark,
      home: Builder(builder: (context) {
        currentContext = context;
        return const Scaffold(body: Text('current screen'));
      })));
    await tester.pumpAndSettle();
    AppToast.show(currentContext, 'Current notice');
    await tester.pumpAndSettle();
    AppToast.showErrorInOverlay(disposedOverlay, 'Stale failure');
    await tester.pump();
    expect(find.text('Current notice'), findsOneWidget);
    expect(find.text('Stale failure'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
