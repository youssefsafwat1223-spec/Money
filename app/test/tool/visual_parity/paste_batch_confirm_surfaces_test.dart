import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/paste_batch_confirm_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'batch-test-memory';
  @override
  Future<String?> readStoredKey() async => 'batch-test-memory';
}

Future<String> _snapshot(AppDatabase db) async {
  final ts = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final t in ts)
      t.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${t.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  });
}

Future<void> _io(WidgetTester t) async {
  await t.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 90)));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final partial in [false, true]) {
        testWidgets(
            'real batch confirm error releases busy and retries $lang dark$dark partial$partial',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase parentDb;
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$w.ttf'));
            }
            await font.load();
            parentDb = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
          addTearDown(() async {
            final close =
                tester.runAsync(() => closeVisualParityPasteBatchConfirm());
            await tester.pump();
            await close;
            parent.dispose();
            await parentDb.close();
          });
          final beforeParent = await tester.runAsync(() => _snapshot(parentDb));
          final repo = parent.read(transactionRepositoryProvider);
          Future<bool?>? opening;
          final root = GlobalKey<NavigatorState>();
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  navigatorKey: root,
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(lang),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) =>
                      Stack(fit: StackFit.expand, children: [
                        child!,
                        ValueListenableBuilder<Widget?>(
                            valueListenable:
                                visualParityPasteBatchConfirmOverlay,
                            builder: (_, v, __) => v ?? const SizedBox.shrink())
                      ]),
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityPasteBatchConfirm(
                                        context,
                                        ref,
                                        partial
                                            ? 'pasteBatchConfirmPartialError'
                                            : 'pasteBatchConfirmError'));
                              },
                              child: const Text('Original')))))));
          final rootState = root.currentState;
          await tester.tap(find.text('Original'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          for (var i = 0; i < 3; i++) {
            await _io(tester);
          }
          final field = find.byType(TextField);
          final pasteContext = tester.element(field);
          final child = ProviderScope.containerOf(pasteContext);
          final db = child.read(appDatabaseProvider);
          final l = AppL10n.of(pasteContext);
          await tester.enterText(field, visualParityPasteBatchMessage());
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          final analyse = find.widgetWithText(FilledButton, l.pasteAnalyse);
          await tester.ensureVisible(analyse);
          await tester.pumpAndSettle();
          await tester.tap(analyse);
          for (var i = 0;
              i < 20 && find.text(l.pasteSummary).evaluate().isEmpty;
              i++) {
            await _io(tester);
          }
          await tester.pumpAndSettle();
          expect(find.text(l.pasteSummary), findsWidgets);
          final rows = (await tester.runAsync(
              () => child.read(transactionRepositoryProvider).getAll()))!;
          expect(rows, hasLength(2));
          expect(
              rows.every((t) => t.status == TransactionStatus.pending), isTrue);
          expect(rows.map((t) => t.amountMoney).toSet(),
              {Money(4500, 'SAR'), Money(8200, 'SAR')});
          expect(
              rows.every((t) => t.source != TransactionSourceEntity.aiParsed),
              isTrue);
          final postIngest = await tester.runAsync(() => _snapshot(db));
          final confirm = find.byType(FilledButton).last;
          await tester.ensureVisible(confirm);
          await tester.pumpAndSettle();
          await tester.tap(confirm);
          await _io(tester);
          expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          final admitted = visualParityPasteBatchConfirmEvents()[
              'pasteBatchConfirmErrorAdmitted']!;
          await tester.tap(confirm, warnIfMissed: false);
          await tester.pump();
          expect(
              visualParityPasteBatchConfirmEvents()[
                  'pasteBatchConfirmErrorAdmitted'],
              admitted);
          final afterFirst = await tester.runAsync(() => _snapshot(db));
          final confirmed = (await tester.runAsync(
                  () => child.read(transactionRepositoryProvider).getAll()))!
              .where((t) => t.status == TransactionStatus.confirmed);
          expect(confirmed, hasLength(partial ? 1 : 0));
          releaseVisualParityPasteBatchConfirm();
          await _io(tester);
          await tester.pump();
          final escaped = tester.takeException();
          final reenables =
              tester.widget<FilledButton>(confirm).onPressed != null;
          final errorShown = find.text(l.txnError).evaluate().isNotEmpty;
          if (reenables) {
            await tester.tap(confirm);
            await _io(tester);
            await tester.pump();
          }
          final retryEscaped = tester.takeException();
          final admissions = visualParityPasteBatchConfirmEvents()[
              'pasteBatchConfirmErrorAdmitted']!;
          expect(await tester.runAsync(() => _snapshot(db)),
              partial ? afterFirst : postIngest);
          expect(parent.read(transactionRepositoryProvider), same(repo));
          expect(root.currentState, same(rootState));
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), beforeParent);
          final close =
              tester.runAsync(() => closeVisualParityPasteBatchConfirm());
          await tester.pump();
          await close;
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(escaped, isNull,
              reason: 'Failure must be handled by actual batch UI');
          expect(retryEscaped, isNull);
          expect(reenables, isTrue,
              reason: 'Failed confirmation must release busy');
          expect(errorShown, isTrue);
          expect(admissions, admitted + 1,
              reason:
                  'Real Retry must invoke first pending confirm again, without any accepted result');
        });
      }
    }
  }
}
