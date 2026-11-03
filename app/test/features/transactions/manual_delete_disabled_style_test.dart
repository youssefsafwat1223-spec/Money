import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/manual_edit_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-delete-paint-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-delete-paint-memory';
}

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pump(const Duration(milliseconds: 350));
}

Color _textPaint(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).text.style!.color!;

BorderSide _paintedBorder(WidgetTester tester, Finder button) {
  final material = tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first);
  return (material.shape! as OutlinedBorder).side;
}

void main() {
  for (final key in [
    'manualEditSaveBusy',
    'manualEditConfirmBusy',
    'manualEditDeleteBusy',
  ]) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('Delete inherits disabled paint $key $language dark=$dark',
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
          addTearDown(() async => db.close());
          Future<bool?>? opening;
          final start = visualParityManualEditOutcomeEvents();
          int delta(String suffix) =>
              (visualParityManualEditOutcomeEvents()['$key$suffix'] ?? 0) -
              (start['$key$suffix'] ?? 0);
          await tester.pumpWidget(ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(db)],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityManualEditOutcome(
                                        context, ref, key));
                              },
                              child: const Text('Open actual editor')))))));
          final outer = tester.state<NavigatorState>(find.byType(Navigator));
          // Drain actual toast timers even when a baseline assertion fails.
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            for (var i = 0; i < 5; i++) {
              await _io(tester);
            }
            await tester.pump(const Duration(seconds: 5));
          });
          await tester.tap(find.text('Open actual editor'));
          expect(await opening, isTrue);
          for (var i = 0; i < 5; i++) {
            await _io(tester);
          }
          final form = find.byType(ManualTransactionSheet);
          final context = tester.element(form);
          final l10n = AppL10n.of(context);
          final delete = find.widgetWithText(OutlinedButton, l10n.txdDeleteTx);
          final label = find.descendant(
              of: delete, matching: find.text(l10n.txdDeleteTx));
          final icon = find.descendant(of: delete, matching: find.byType(Icon));
          final iconGlyph =
              find.descendant(of: icon, matching: find.byType(RichText));
          await tester.scrollUntilVisible(delete, 160,
              scrollable: find
                  .descendant(of: form, matching: find.byType(Scrollable))
                  .first);
          final buttonContext = tester.element(delete);
          final danger = Theme.of(buttonContext).extension<AppColors>()!.danger;
          await tester.pumpAndSettle();
          expect(delete.hitTestable(), findsOneWidget);
          expect(_textPaint(tester, label), danger,
              reason: 'Enabled destructive label retains its approved red');
          expect(_textPaint(tester, iconGlyph), danger,
              reason: 'Enabled destructive icon retains its approved red');
          expect(_paintedBorder(tester, delete), BorderSide(color: danger));
          final save = find.widgetWithText(FilledButton, l10n.mtSaveEdits);
          final confirm = find.widgetWithText(FilledButton, l10n.txdConfirmTx);
          final action = key.contains('Save')
              ? save
              : key.contains('Confirm')
                  ? confirm
                  : delete;
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          await tester.tap(action);
          if (key.contains('Delete')) {
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(TextButton, l10n.setDelete));
          }
          await _io(tester);
          await tester.ensureVisible(delete);
          await tester.pump(const Duration(milliseconds: 400));
          expect(delta('Attempt'), 1);
          expect(delta('Held'), 1);
          final actual = tester.widget<OutlinedButton>(delete);
          expect(actual.onPressed, isNull);
          const disabled = {WidgetState.disabled};
          final themeStyle = OutlinedButtonTheme.of(buttonContext).style;
          final defaults = actual.defaultStyleOf(buttonContext);
          final expectedForeground =
              themeStyle?.foregroundColor?.resolve(disabled) ??
                  defaults.foregroundColor!.resolve(disabled)!;
          final expectedBorder = themeStyle?.side?.resolve(disabled) ??
              defaults.side!.resolve(disabled)!;
          final labelPaint = _textPaint(tester, label);
          final iconPaint = _textPaint(tester, iconGlyph);
          final borderPaint = _paintedBorder(tester, delete);
          expect(expectedForeground, isNot(danger));
          expect(expectedBorder.color, isNot(danger));
          await tester.tap(delete, warnIfMissed: false);
          await tester.pump();
          expect(delta('Attempt'), 1);
          expect(delta('ForbiddenDoubleAdmission'), 0);
          outer.pop();
          for (var i = 0; i < 40 && delta('Closed') == 0; i++) {
            await _io(tester);
          }
          expect(delta('Closed'), 1);
          expect(delta('AllSqlUnchanged'), 1);
          expect(
              visualParityManualEditOutcomeReceipts()[key]![
                  'childAllSqlUnchanged'],
              isTrue);
          expect(delta('ForbiddenBillCleanup'), 0);
          await tester.pump(const Duration(seconds: 5));
          expect(tester.takeException(), isNull);
          expect(labelPaint, expectedForeground,
              reason:
                  'Disabled label must paint the actual inherited theme state');
          expect(iconPaint, expectedForeground,
              reason:
                  'Disabled icon must paint the actual inherited theme state');
          expect(borderPaint, expectedBorder,
              reason:
                  'Disabled border must paint the actual inherited theme state');
        });
      }
    }
  }
}
