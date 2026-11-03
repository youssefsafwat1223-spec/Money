import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-pricing-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-pricing-memory';
}

class _NoConfirm extends DriftTransactionRepository {
  _NoConfirm(super.db);
  int attempts = 0;
  @override
  Future<TransactionEntity> confirm(String id) async {
    attempts++;
    throw StateError('confirmation must not execute');
  }
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

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final awaiting in [true, false]) {
        testWidgets(
            'manual confirmation requires persisted home price $language dark=$dark awaiting=$awaiting',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          late ProviderContainer container;
          late _NoConfirm repository;
          late TransactionEntity opened;
          await tester.runAsync(() async {
            for (final family in [
              'Vazirmatn',
              'Alexandria',
              'IBMPlexSansArabic'
            ]) {
              final font = FontLoader(family);
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await font.load();
            }
            db = await AppDatabase.open(
                executor: NativeDatabase.memory(),
                keyStore: _Keys(),
                initialLanguage: language);
            repository = _NoConfirm(db);
            container = ProviderContainer(overrides: [
              appDatabaseProvider.overrideWithValue(db),
              localeProvider.overrideWithValue(Locale(language)),
              transactionRepositoryProvider.overrideWithValue(repository),
              confirmTransactionUseCaseProvider
                  .overrideWithValue(ConfirmTransactionUseCase(repository)),
            ]);
            final at = DateTime.utc(2026, 11, 1);
            final account = await container
                .read(accountRepositoryProvider)
                .create(AccountEntity(
                    id: 'manual-pricing-account',
                    name: 'QA EGP account',
                    currency: 'EGP',
                    type: AccountType.bank,
                    isDefault: true,
                    sortOrder: 0,
                    createdAt: at,
                    updatedAt: at,
                    initialBalanceMoney: Money.zero('EGP'),
                    currentBalanceMoney: Money.zero('EGP')));
            opened = await repository.saveTransaction(
                transaction: TransactionEntity(
                    id: 'qa-manual-awaiting',
                    accountId: account.id,
                    amountMoney: Money.zero('EGP'),
                    currency: 'EGP',
                    foreignMoney: awaiting ? Money(12345, 'KWD') : null,
                    foreignCurrency: awaiting ? 'KWD' : null,
                    type: TransactionTypeEntity.payment,
                    source: TransactionSourceEntity.bank,
                    occurredAt: at,
                    rawMessage: 'Synthetic pending price',
                    rawMerchant: 'QA purchase',
                    parseConfidence: .6,
                    status: TransactionStatus.pending,
                    createdAt: at,
                    updatedAt: at),
                categoryKey: 'groceries');
          });
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          final before = await tester.runAsync(() => _snapshot(db));
          await tester.pumpWidget(UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  supportedLocales: AppL10n.supportedLocales,
                  home: Builder(
                      builder: (context) => Scaffold(
                          body: TextButton(
                              onPressed: () => ManualTransactionSheet.show(
                                  context,
                                  transaction: opened),
                              child: const Text('Open edit')))))));
          await tester.tap(find.text('Open edit'));
          await _flush(tester);
          final l10n =
              AppL10n.of(tester.element(find.byType(ManualTransactionSheet)));
          final confirm = find.widgetWithText(FilledButton, l10n.txdConfirmTx);
          await tester.ensureVisible(confirm);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(confirm).onPressed,
              awaiting ? isNull : isNotNull);
          expect(
              opened.pricingState,
              awaiting
                  ? TransactionPricingState.awaitingFx
                  : TransactionPricingState.priced);
          if (!awaiting) {
            // A genuine zero with no foreign amount preserves its legacy enabled
            // confirmation policy; this test deliberately never confirms it.
            expect(repository.attempts, 0);
            Navigator.of(tester.element(find.byType(ManualTransactionSheet)))
                .pop();
            await tester.pumpAndSettle();
            expect(await tester.runAsync(() => _snapshot(db)), before);
            return;
          }
          await tester.tap(confirm, warnIfMissed: false);
          await tester.pump();
          expect(repository.attempts, 0);
          final amount = find.byType(TextField).first;
          await tester.ensureVisible(amount);
          await tester.enterText(amount, '12.34');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          await tester.ensureVisible(confirm);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(confirm).onPressed, isNull,
              reason: 'A draft value does not price the stored transaction');
          expect(await tester.runAsync(() => _snapshot(db)), before);
          final save = find.widgetWithText(FilledButton, l10n.mtSaveEdits);
          await tester.ensureVisible(save);
          await tester.tap(save);
          await _flush(tester);
          expect(find.byType(ManualTransactionSheet), findsNothing);
          final saved =
              (await tester.runAsync(() => repository.getById(opened.id)))!;
          expect(saved.amountMoney, Money(1234, 'EGP'));
          expect(saved.currency, 'EGP');
          expect(saved.foreignMoney, Money(12345, 'KWD'));
          expect(saved.foreignCurrency, 'KWD');
          expect(saved.accountId, opened.accountId);
          expect(saved.rawMessage, opened.rawMessage);
          expect(saved.pricingState, TransactionPricingState.priced);
          // The existing Save flow itself confirms a validated user edit. No
          // Confirm use case/repository method was accepted or invoked here.
          expect(saved.status, TransactionStatus.confirmed);
          expect(repository.attempts, 0);
          final after = (await tester.runAsync(() => _snapshot(db)))!;
          for (final table in before!.keys) {
            if (table != 'transactions' &&
                table != 'proof_correction_events' &&
                table != 'merchants') {
              expect(after[table], before[table],
                  reason: 'Unexpected write to $table');
            }
          }
          final oldRows = before['transactions']! as List;
          final newRows = after['transactions']! as List;
          expect(oldRows, hasLength(1));
          expect(newRows, hasLength(1));
          final oldRow = oldRows.single as Map;
          final newRow = newRows.single as Map;
          for (final column in oldRow.keys) {
            if (!{
              'amount',
              'amount_minor',
              'status',
              'updated_at',
              'comparison_timestamp'
            }.contains(column)) {
              expect(newRow[column], oldRow[column],
                  reason: 'Unexpected transaction column $column');
            }
          }
          expect(newRow['amount'], 12.34);
          expect(newRow['amount_minor'], 1234);
          expect(newRow['status'], 'confirmed');
          expect(newRow['comparison_timestamp'], oldRow['occurred_at']);
          // The actual repository refreshes only the existing merchant's
          // last-seen timestamp; there must be no merchant insert or rewrite.
          final oldMerchants = before['merchants']! as List;
          final newMerchants = after['merchants']! as List;
          expect(newMerchants, hasLength(oldMerchants.length));
          for (var i = 0; i < oldMerchants.length; i++) {
            final oldMerchant = oldMerchants[i] as Map;
            final newMerchant = newMerchants[i] as Map;
            for (final column in oldMerchant.keys) {
              if (column == 'last_seen_at' &&
                  oldMerchant['id'] == oldRow['merchant_id']) {
                expect(
                    DateTime.parse(newMerchant[column] as String).isBefore(
                        DateTime.parse(oldMerchant[column] as String)),
                    isFalse);
              } else {
                expect(newMerchant[column], oldMerchant[column]);
              }
            }
          }
          final oldProofs = before['proof_correction_events']! as List;
          final newProofs = after['proof_correction_events']! as List;
          expect(newProofs, hasLength(oldProofs.length + 1));
          expect(newProofs.take(oldProofs.length).toList(), oldProofs);
          expect((newProofs.last as Map)['transaction_id'], opened.id);
          expect((newProofs.last as Map)['event_type'], 'corrected_financial');
          expect((newProofs.last as Map)['changed_fields'], 'amount');
          opened = saved;
          await tester.tap(find.text('Open edit'));
          await _flush(tester);
          final confirmed =
              find.widgetWithText(FilledButton, l10n.mtTxConfirmed);
          await tester.ensureVisible(confirmed);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(confirmed).onPressed, isNull);
          expect(repository.attempts, 0);
          Navigator.of(tester.element(find.byType(ManualTransactionSheet)))
              .pop();
          await tester.pumpAndSettle();
          expect(await tester.runAsync(() => _snapshot(db)), after,
              reason: 'Reopening the persisted priced row must only read');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
