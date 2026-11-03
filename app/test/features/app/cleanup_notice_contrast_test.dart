import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/features/app/local_read_cleanup_notice.dart';
import 'package:money_companion/l10n/app_localizations.dart';

double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
}
void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('cleanup enabled actions readable and retry remains safe $language dark=$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var calls = 0;
        final held = Completer<bool>();
        late AppL10n l10n;
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Builder(builder: (context) {
            l10n = AppL10n.of(context);
            return Scaffold(body: TextButton(onPressed: () => showSignOutIncompleteNotice(
              Navigator.of(context), l10n, retry: () { calls++; return held.future; }), child: const Text('Open cleanup')));
          }),
        ));
        await tester.tap(find.text('Open cleanup'));
        await tester.pumpAndSettle();
        void verifyEnabledAction(String key) {
          final button = find.byKey(Key(key));
          expect(tester.widget<TextButton>(button).onPressed, isNotNull);
          final label = find.descendant(of: button, matching: find.byType(Text));
          final paragraph = tester.renderObject<RenderParagraph>(label);
          Color? background;
          tester.element(button).visitAncestorElements((element) {
            if (element.widget case Material(color: final Color color)) {
              if (color.a > .99) { background = color; return false; }
            }
            return true;
          });
          expect(background, isNotNull);
          expect(_contrast(paragraph.text.style!.color!, background!), greaterThanOrEqualTo(4.5));
        }
        verifyEnabledAction('sign_out_incomplete_retry');
        verifyEnabledAction('sign_out_incomplete_close');
        final retry = find.byKey(const Key('sign_out_incomplete_retry'));
        await tester.tap(retry);
        await tester.pump();
        expect(calls, 1);
        expect(tester.widget<TextButton>(retry).onPressed, isNull);
        await tester.tap(retry, warnIfMissed: false);
        await tester.pump();
        expect(calls, 1);
        held.complete(false);
        await tester.pumpAndSettle();
        expect(find.text(l10n.signOutCleanupStillIncomplete), findsOneWidget);
        verifyEnabledAction('sign_out_incomplete_retry');
        verifyEnabledAction('sign_out_incomplete_close');
        await tester.tap(find.byKey(const Key('sign_out_incomplete_close')));
        await tester.pumpAndSettle();
        expect(find.byType(GlassAlertDialog), findsNothing);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
