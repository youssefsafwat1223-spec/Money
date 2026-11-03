import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/rules_client.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'fee-probe-memory';
  @override
  Future<String?> readStoredKey() async => 'fee-probe-memory';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('observe actual full engine foreign purchase fee', () async {
    var networkCalls = 0;
    await HttpOverrides.runZoned(() async {
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(),
          keyStore: _Keys(),
          initialLanguage: 'en');
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      try {
        final settings = await DriftUserSettingsRepository(db).getSettings();
        expect(settings.cloudProcessingEnabled, isFalse);
        final accounts = DriftAccountRepository(db);
        final transactions = DriftTransactionRepository(db);
        final now = DateTime.utc(2026, 6, 24, 11, 42);
        await accounts.create(AccountEntity(
            id: 'qa-fee-sar',
            name: 'QA SAR',
            currency: 'SAR',
            type: AccountType.bank,
            isDefault: true,
            sortOrder: 0,
            initialBalanceMoney: Money.zero('SAR'),
            currentBalanceMoney: Money.zero('SAR'),
            createdAt: now,
            updatedAt: now));
        final coordinator = container.read(planningCutoverCoordinatorProvider)
            as DbBackedPlanningCutoverCoordinator;
        await coordinator.refreshFromDatabase();
        final rules = RulesClient(database: db);
        final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
            transactionRepository: transactions,
            accountRepository: accounts,
            merchantCategoryRepository: DriftMerchantCategoryRepository(db),
            suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
            dedupStore: DriftDedupStore(db),
            coordinator: coordinator,
            loadBankProfiles: ({String? senderId}) =>
                rules.localBankProfiles(senderId: senderId),
            loadCatalogRules: rules.catalogRulesForSender));
        const raw =
            'شراء إنترنت\nبطاقة:7640; urpay بطاقة;\nمبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE.CO..\n24-6-2026 11:42';
        final result = await ingest.fromCapturedMessage(CapturedMessage(
            text: raw,
            source: CapturedMessageSource.manualPaste,
            receivedAt: now));
        Map<String, Object?> describe(AddTransactionResult? value) => {
              'outcome': value?.outcome.name,
              'id': value?.transaction?.id,
              'amountMinor': value?.transaction?.amountMoney.minorUnits,
              'currency': value?.transaction?.currency,
              'foreignMinor': value?.transaction?.foreignMoney?.minorUnits,
              'foreignCurrency': value?.transaction?.foreignCurrency,
              'status': value?.transaction?.status.name,
              'source': value?.transaction?.source.name,
              'pricingState': value?.transaction?.pricingState.name,
              'requiresConfirmation': value?.requiresConfirmation,
              'aiFailureReason': value?.aiFailureReason
            };
        final rows = (await db
                .customSelect('SELECT * FROM transactions ORDER BY rowid')
                .get())
            .map((r) => r.data)
            .toList();
        final report = {
          'actualParserIsolate': true,
          'disposition': result.disposition.name,
          'primary': describe(result.addTransactionResult),
          'secondary': describe(result.addTransactionResult.secondary),
          'transactionRows': rows,
          'accounts': (await db
                  .customSelect('SELECT * FROM accounts ORDER BY rowid')
                  .get())
              .map((r) => r.data)
              .toList(),
          'coordinatorState': coordinator.state().name,
          'noAiClientConstructed': true,
          'noCaptureOrForceFlag': true,
          'actualCloudProcessingEnabled': settings.cloudProcessingEnabled,
          'httpClientAttempts': networkCalls
        };
        final evidenceDirectory =
            Directory.systemTemp.createTempSync('qirsh-test-evidence-');
        addTearDown(() => evidenceDirectory.deleteSync(recursive: true));
        File('${evidenceDirectory.path}/confirmation-fee-actual-probe-result.json')
            .writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(report));
        final primary = result.addTransactionResult;
        expect(primary.outcome, AddTransactionOutcome.added);
        expect(primary.secondary?.outcome, AddTransactionOutcome.added);
        expect(
            primary.transaction!.id, isNot(primary.secondary!.transaction!.id));
        expect(primary.transaction!.amountMoney, Money.zero('SAR'));
        expect(primary.transaction!.foreignMoney, Money(9900, 'USD'));
        expect(primary.transaction!.status, TransactionStatus.pending);
        expect(primary.transaction!.pricingState,
            TransactionPricingState.awaitingFx);
        expect(primary.secondary!.transaction!.amountMoney, Money(744, 'SAR'));
        expect(primary.secondary!.transaction!.status,
            TransactionStatus.confirmed);
        expect(
            result.disposition, CapturedMessageDisposition.requestConfirmation);
        expect(primary.aiFailureReason, 'no_ai_client');
        expect(coordinator.state(), PlanningCutoverState.canonical);
        expect(rows, hasLength(2));
        for (final tx in [
          primary.transaction!,
          primary.secondary!.transaction!
        ]) {
          final row = rows.singleWhere((row) => row['id'] == tx.id);
          expect(row['amount_minor'], tx.amountMoney.minorUnits);
          expect(row['currency'], tx.currency);
          expect(row['status'], tx.status.name);
          expect(row['account_id'], 'qa-fee-sar');
          final readback = (await transactions.getById(tx.id))!;
          expect(readback.amountMoney, tx.amountMoney);
          expect(readback.foreignMoney, tx.foreignMoney);
        }
        final mainRow =
            rows.singleWhere((row) => row['id'] == primary.transaction!.id);
        expect(mainRow['foreign_amount_minor'], 9900);
        expect(mainRow['foreign_currency'], 'USD');
        expect(networkCalls, 0);
      } finally {
        container.dispose();
        await db.close();
      }
    }, createHttpClient: (context) {
      networkCalls++;
      throw StateError('probe remote client forbidden');
    });
  });
}
