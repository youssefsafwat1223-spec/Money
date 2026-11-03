import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.9411764705882353]) {
        testWidgets(
            'public paste sheet header wraps and closes $language dark=$dark scale=$scale',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          for (final family in [
            'Vazirmatn',
            'Alexandria',
            'IBMPlexSansArabic'
          ]) {
            final loader = FontLoader(family);
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              loader
                  .addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
            }
            await loader.load();
          }
          var added = 0;
          await tester.pumpWidget(ProviderScope(
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!),
                  home: Builder(
                      builder: (context) => Scaffold(
                          body: TextButton(
                              onPressed: () => ManualPasteScreen.showSheet(
                                  context,
                                  onTransactionAdded: (_) => added++),
                              child: const Text('Open paste')))))));
          await tester.tap(find.text('Open paste'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason:
                  'The actual public header must not overflow at large text');
          final field = find.byType(TextField);
          final l10n = AppL10n.of(tester.element(field));
          final title = find.text(l10n.pasteTitle);
          final paragraph = tester.renderObject<RenderParagraph>(title);
          final titleRect = tester.getRect(title);
          final close = find.byType(IconButton);
          final closeRect = tester.getRect(close);
          const screen = Rect.fromLTWH(0, 0, 375, 667);
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(screen.contains(titleRect.topLeft), isTrue);
          expect(screen.contains(titleRect.bottomRight), isTrue);
          expect(screen.contains(closeRect.topLeft), isTrue);
          expect(screen.contains(closeRect.bottomRight), isTrue);
          expect(titleRect.overlaps(closeRect), isFalse);
          expect(close.hitTestable(), findsOneWidget);
          if (scale > 1.5 && language == 'en') {
            expect(
                paragraph
                    .getBoxesForSelection(TextSelection(
                        baseOffset: 0, extentOffset: l10n.pasteTitle.length))
                    .map((box) => box.top)
                    .toSet()
                    .length,
                greaterThan(1),
                reason: 'Large title retains every word by wrapping naturally');
          }
          final scrollable = find.byType(SingleChildScrollView);
          for (final control in [
            find.widgetWithText(OutlinedButton, l10n.pasteFromClipboard),
            find.widgetWithText(FilledButton, l10n.pasteAnalyse),
          ]) {
            await tester.scrollUntilVisible(control, 100,
                scrollable: find
                    .descendant(
                        of: scrollable, matching: find.byType(Scrollable))
                    .first);
            await tester.pumpAndSettle();
            final rect = tester.getRect(control);
            expect(rect.top, greaterThanOrEqualTo(closeRect.bottom));
            expect(rect.bottom, lessThanOrEqualTo(screen.bottom));
            expect(control.hitTestable(), findsOneWidget);
            expect(tester.getRect(title), titleRect,
                reason: 'Body scroll keeps the header fixed and readable');
            expect(tester.takeException(), isNull);
          }
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          expect(added, 0,
              reason:
                  'Layout verification does not ingest or accept a message');
          await tester.tap(close);
          await tester.pumpAndSettle();
          expect(title, findsNothing);
          expect(find.text('Open paste'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
