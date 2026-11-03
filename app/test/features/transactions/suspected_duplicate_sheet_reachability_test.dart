import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'suspect-layout-memory';
  @override
  Future<String?> readStoredKey() async => 'suspect-layout-memory';
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
          .map((r) => r.data)
          .toList()
  };
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.9411764705882353]) {
        testWidgets(
            'actual suspect review controls reachable $language dark=$dark scale=$scale',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          late ProviderContainer container;
          late String suspectId;
          await tester.runAsync(() async {
            for (final family in [
              'Vazirmatn',
              'Alexandria',
              'IBMPlexSansArabic'
            ]) {
              final loader = FontLoader(family);
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                loader.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await loader.load();
            }
            db = await AppDatabase.open(
                executor: NativeDatabase.memory(),
                keyStore: _Keys(),
                initialLanguage: language);
            container = ProviderContainer(overrides: [
              appDatabaseProvider.overrideWithValue(db),
              localeProvider.overrideWithValue(Locale(language))
            ]);
            final at = DateTime.utc(2026, 4, 8);
            final accounts = container.read(accountRepositoryProvider);
            await accounts.create(AccountEntity(
                id: 'qa-suspect-account',
                name: 'QA SAR',
                currency: 'SAR',
                type: AccountType.bank,
                isDefault: true,
                sortOrder: 0,
                createdAt: at,
                updatedAt: at,
                initialBalanceMoney: Money.zero('SAR'),
                currentBalanceMoney: Money.zero('SAR')));
            final coordinator =
                container.read(planningCutoverCoordinatorProvider)
                    as DbBackedPlanningCutoverCoordinator;
            await coordinator.refreshFromDatabase();
            final suspected = DriftSuspectedDuplicateRepository(db);
            final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
                transactionRepository: DriftTransactionRepository(db),
                merchantCategoryRepository: DriftMerchantCategoryRepository(db),
                suspectedDuplicateRepository: suspected,
                accountRepository: accounts,
                coordinator: coordinator));
            const text =
                'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\nلدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
            final message = CapturedMessage(
                text: text,
                source: CapturedMessageSource.manualPaste,
                receivedAt: at);
            await ingest.fromCapturedMessage(message);
            final repeated = await ingest.fromCapturedMessage(message);
            expect(repeated.addTransactionResult.outcome,
                AddTransactionOutcome.suspiciousDuplicate);
            suspectId = repeated.addTransactionResult.suspectedDuplicateId!;
          });
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          final suspect = (await tester.runAsync(() => container
                  .read(suspectedDuplicateRepositoryProvider)
                  .getAll()))!
              .single;
          expect(suspect.id, suspectId);
          final before = await tester.runAsync(() => _snapshot(db));
          late AppL10n l10n;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!),
                  home: Builder(builder: (context) {
                    l10n = AppL10n.of(context);
                    return Scaffold(
                        body: TextButton(
                            onPressed: () => showSuspectedDuplicateReviewSheet(
                                context, suspect),
                            child: const Text('Open actual suspect')));
                  }))));
          await tester.tap(find.text('Open actual suspect'));
          await tester.runAsync(() async =>
              Future<void>.delayed(const Duration(milliseconds: 80)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final heading = find.text(l10n.txnSimilarExists);
          await tester.ensureVisible(heading);
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(heading);
          expect(paragraph.didExceedMaxLines, isFalse,
              reason:
                  'The complete suspected-duplicate heading must be visible');
          if (language == 'en') {
            const word = 'transaction';
            final start = l10n.txnSimilarExists.indexOf(word);
            expect(start, greaterThanOrEqualTo(0));
            final wordBoxes = paragraph.getBoxesForSelection(TextSelection(
                baseOffset: start, extentOffset: start + word.length));
            expect(wordBoxes, isNotEmpty);
            expect(wordBoxes.map((box) => box.top).toSet(), hasLength(1),
                reason: 'The heading must wrap between words, keeping the word '
                    'transaction complete on one line');
          }
          final bounds = tester.getRect(heading);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(375));
          expect(heading.hitTestable(), findsOneWidget);
          for (final label in language == 'en'
              ? [
                  l10n.txnEditTx,
                  l10n.txnChangeCategory,
                  l10n.txnDismissDuplicate,
                  l10n.txnSaveAsNew
                ]
              : [
                  l10n.txnDismissDuplicate,
                  l10n.txnSaveAsNew,
                  l10n.txnEditTx,
                  l10n.txnChangeCategory
                ]) {
            final control = find.text(label);
            await tester.ensureVisible(control);
            await tester.pumpAndSettle();
            expect(control.hitTestable(), findsOneWidget, reason: label);
            final button = find
                .ancestor(
                    of: control,
                    matching: find.byWidgetPredicate(
                        (widget) => widget is ButtonStyleButton))
                .first;
            final actualButton = tester.widget<ButtonStyleButton>(button);
            expect(actualButton.onPressed, isNotNull, reason: label);
            expect(button.hitTestable(), findsOneWidget, reason: label);
            if (language == 'en' && label == l10n.txnEditTx) {
              const word = 'transaction';
              final start = label.indexOf(word);
              expect(start, greaterThanOrEqualTo(0));
              final paragraph = tester.renderObject<RenderParagraph>(control);
              final wordBoxes = paragraph.getBoxesForSelection(TextSelection(
                  baseOffset: start, extentOffset: start + word.length));
              expect(wordBoxes, isNotEmpty);
              expect(wordBoxes.map((box) => box.top).toSet(), hasLength(1),
                  reason: 'The Edit action must keep transaction on one line');
            }
            final paint = find
                .descendant(of: button, matching: find.byType(Material))
                .first;
            final paintedBounds = tester.getRect(paint);
            final labelBounds = tester.getRect(control);
            expect(
                labelBounds.left, greaterThanOrEqualTo(paintedBounds.left + 4),
                reason: 'Action labels must retain space inside rounded edges');
            expect(
                labelBounds.right, lessThanOrEqualTo(paintedBounds.right - 4),
                reason: 'Action labels must retain space inside rounded edges');
            expect(labelBounds.top, greaterThanOrEqualTo(paintedBounds.top));
            expect(labelBounds.bottom, lessThanOrEqualTo(paintedBounds.bottom));
            expect(tester.takeException(), isNull);
          }
          expect(await tester.runAsync(() => _snapshot(db)), before);
          Navigator.of(tester.element(find.text(l10n.txnSaveAsNew))).pop();
          await tester.pumpAndSettle();
          expect(find.text('Open actual suspect'), findsOneWidget);
          expect(await tester.runAsync(() => _snapshot(db)), before);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
