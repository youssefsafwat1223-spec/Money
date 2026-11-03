import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/card_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'card-delete-paint-memory';
  @override
  Future<String?> readStoredKey() async => 'card-delete-paint-memory';
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  };
}

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final key in ['cardFormSaving', 'cardFormDeleting']) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            'Card Delete inherits disabled paint $key $language dark=$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
            db = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(db)]);
          addTearDown(() async {
            final closing = closeVisualParityCardOutcome();
            await tester.pumpAndSettle();
            await tester.runAsync(() => closing);
            parent.dispose();
            await db.close();
          });
          final parentBefore = await tester.runAsync(() => _snapshot(db));
          final events = visualParityCardOutcomeEvents();
          Future<bool?>? opening;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) =>
                      Stack(fit: StackFit.expand, children: [
                        child!,
                        ValueListenableBuilder<Widget?>(
                            valueListenable: visualParityCardOutcomeOverlay,
                            builder: (_, overlay, __) =>
                                overlay ?? const SizedBox.shrink())
                      ]),
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityCardOutcome(
                                        context, ref, key));
                              },
                              child: const Text('Open actual card')))))));
          await tester.tap(find.text('Open actual card'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          await _io(tester);
          final field = find.byType(TextField).first;
          final formContext = tester.element(field);
          final childDb =
              ProviderScope.containerOf(formContext).read(appDatabaseProvider);
          final childBefore = await tester.runAsync(() => _snapshot(childDb));
          final l10n = AppL10n.of(formContext);
          final delete = find.widgetWithText(TextButton, l10n.cfDeleteCard);
          await tester.ensureVisible(delete);
          await tester.pumpAndSettle();
          final context = tester.element(delete);
          final danger = Theme.of(context).extension<AppColors>()!.danger;
          final label = find.descendant(
              of: delete, matching: find.text(l10n.cfDeleteCard));
          final icon = find.descendant(of: delete, matching: find.byType(Icon));
          final iconGlyph =
              find.descendant(of: icon, matching: find.byType(RichText));
          TextStyle painted(Finder finder) =>
              tester.renderObject<RenderParagraph>(finder).text.style!;
          final enabledLabel = painted(label);
          final enabledIcon = painted(iconGlyph);
          final body = AppTypography.body(danger);
          expect(enabledLabel.color, danger);
          expect(enabledIcon.color, danger);
          expect(enabledLabel.fontFamily, body.fontFamily);
          expect(enabledLabel.fontFamilyFallback, body.fontFamilyFallback);
          expect(enabledLabel.fontSize, body.fontSize);
          expect(enabledLabel.fontWeight, body.fontWeight);
          expect(enabledLabel.height, body.height);
          expect(enabledLabel.letterSpacing, body.letterSpacing);
          expect(delete.hitTestable(), findsOneWidget);
          if (key == 'cardFormSaving') {
            await tester.enterText(field, 'QA revised card');
            tester.testTextInput.hide();
            final save = find.widgetWithText(FilledButton, l10n.txdSave);
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            await tester.tap(save);
          } else {
            await tester.tap(delete);
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(TextButton, l10n.setDelete));
          }
          await _io(tester);
          await tester.ensureVisible(delete);
          await tester.pump(const Duration(milliseconds: 400));
          expect(visualParityCardOutcomeEvents()[key], (events[key] ?? 0) + 1);
          final actual = tester.widget<TextButton>(delete);
          expect(actual.onPressed, isNull);
          const disabled = {WidgetState.disabled};
          final theme = TextButtonTheme.of(context).style;
          final expected = theme?.foregroundColor?.resolve(disabled) ??
              actual
                  .defaultStyleOf(context)
                  .foregroundColor!
                  .resolve(disabled)!;
          final busyLabel = painted(label).color;
          final busyIcon = painted(iconGlyph).color;
          expect(expected, isNot(danger));
          await tester.tap(delete, warnIfMissed: false);
          await tester.pump();
          expect(visualParityCardOutcomeEvents()[key], (events[key] ?? 0) + 1);
          expect(await tester.runAsync(() => _snapshot(childDb)), childBefore);
          final close = closeVisualParityCardOutcome();
          await tester.pumpAndSettle();
          for (var i = 0;
              i < 20 &&
                  (visualParityCardOutcomeEvents()['${key}Closed'] ?? 0) ==
                      (events['${key}Closed'] ?? 0);
              i++) {
            await _io(tester);
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() => close);
          expect(visualParityCardOutcomeEvents()['${key}Closed'],
              (events['${key}Closed'] ?? 0) + 1);
          expect(
              visualParityCardOutcomeEvents()['cardOutcomeForbiddenWrite'] ?? 0,
              events['cardOutcomeForbiddenWrite'] ?? 0);
          expect(await tester.runAsync(() => _snapshot(db)), parentBefore);
          expect(tester.takeException(), isNull);
          expect(busyLabel, expected,
              reason:
                  'Disabled Delete label must paint the actual SDK/theme state');
          expect(busyIcon, expected,
              reason:
                  'Disabled Delete icon must paint the actual SDK/theme state');
        });
      }
    }
  }
}
