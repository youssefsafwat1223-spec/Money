// Actual offline capture results in owned memory. Never imported by lib/.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/rules_client.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';

const visualParityPasteBatchConfirmKeys = [
  'pasteBatchConfirmError',
  'pasteBatchConfirmPartialError'
];
final visualParityPasteBatchConfirmOverlay = ValueNotifier<Widget?>(null);
_PasteBatchFixture? _active;
BuildContext? get visualParityPasteBatchInspectionContext =>
    _active?.navigator.currentContext;
const _known = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _unknown = 'عملية شراء\nمبلغ:SAR 82.00\n'
    'لدى:LOCAL ROASTER\nفي:2026-04-08 18:30';
String visualParityPasteBatchMessage() => '$_known\n\n$_unknown';
final _events = <String, int>{};
Map<String, int> visualParityPasteBatchConfirmEvents() =>
    Map.unmodifiable(_events);
// Actual returned result metadata only, never raw SMS, sender or notification
// fingerprint. This is not a SQL readback or a live authority/capability.
final _receipts = <String, Map<String, Object?>>{};
Map<String, Map<String, Object?>> visualParityPasteBatchConfirmReceipts() =>
    Map.unmodifiable(_receipts);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);

// Calls the actual implementation unchanged, retaining only its real output.
class _ObservedIngest extends IngestCapturedMessageUseCase {
  _ObservedIngest(AddTransactionUseCase useCase, this.key) : super(useCase);
  final String key;
  CapturedMessageResult? latest;
  @override
  Future<CapturedMessageResult> fromCapturedMessage(
    CapturedMessage message, {
    bool onDeviceOnly = false,
    CaptureCommit? capture,
    bool forceLocalAutoConfirm = false,
  }) async {
    if (message.source != CapturedMessageSource.manualPaste ||
        onDeviceOnly ||
        capture != null ||
        forceLocalAutoConfirm ||
        message.senderId != null) {
      throw StateError('paste_result_unexpected_authority_or_source');
    }
    final actual = await super.fromCapturedMessage(message);
    latest = actual;
    final result = actual.addTransactionResult;
    final transaction = result.transaction;
    _receipts[key] = Map.unmodifiable({
      'syntheticOnly': true,
      'outcome': result.outcome.name,
      'disposition': actual.disposition.name,
      'transactionId': transaction?.id,
      'transactionStatus': transaction?.status.name,
      'amountMinor': transaction?.amountMoney.minorUnits,
      'currency': transaction?.currency,
      'transactionSource': transaction?.source.name,
      'requiresConfirmation': result.requiresConfirmation,
      'isNewMerchant': result.isNewMerchant,
      'aiFailureReason': result.aiFailureReason,
      'suspectedDuplicateId': result.suspectedDuplicateId,
    });
    _record('${key}ActualIngest');
    return actual;
  }
}

class _BatchTransactions extends DriftTransactionRepository {
  _BatchTransactions(super.db, this.allowFirst);
  final bool allowFirst;
  int confirmCalls = 0;
  final gate = Completer<void>();
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<TransactionEntity> confirm(String transactionId) async {
    final actual = await getById(transactionId);
    if (actual == null ||
        actual.status != TransactionStatus.pending ||
        actual.currency != 'SAR') {
      throw StateError('batch_confirm_unexpected_input');
    }
    confirmCalls++;
    if (allowFirst && confirmCalls == 1) return super.confirm(transactionId);
    _record('pasteBatchConfirmErrorAdmitted');
    await gate.future;
    throw StateError('private_batch_confirm_failure');
  }
}

void releaseVisualParityPasteBatchConfirm() => _active?.transactions.release();
Map<String, Object?> visualParityPasteBatchConfirmReceipt() => {
      'confirmCalls': _active?.transactions.confirmCalls,
    };

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'owned-paste-memory';
  @override
  Future<String?> readStoredKey() async => 'owned-paste-memory';
}

Future<bool> openVisualParityPasteBatchConfirm(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityPasteBatchConfirmKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('paste_result_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final parent = ref.read(appDatabaseProvider);
  final rows = await parent.customSelect('PRAGMA database_list').get();
  if (!rows.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('paste_result_requires_memory_database');
  }
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  Future<void>? closing;
  Future<void> close() => closing ??= (() async {
        container?.dispose();
        await db.close();
        _record('${key}Closed');
      })();
  try {
    final accounts = DriftAccountRepository(db);
    final transactions =
        _BatchTransactions(db, key == 'pasteBatchConfirmPartialError');
    final merchants = DriftMerchantCategoryRepository(db);
    final suspected = DriftSuspectedDuplicateRepository(db);
    final now = DateTime.utc(2026, 4, 8);
    await accounts.create(AccountEntity(
        id: 'qa-paste-sar',
        name: 'QA isolated SAR account',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        initialBalanceMoney: Money.zero('SAR'),
        currentBalanceMoney: Money.zero('SAR'),
        createdAt: now,
        updatedAt: now));
    late _ObservedIngest ingest;
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      accountRepositoryProvider.overrideWithValue(accounts),
      categoryRepositoryProvider.overrideWithValue(DriftCategoryRepository(db)),
      transactionRepositoryProvider.overrideWithValue(transactions),
      merchantCategoryRepositoryProvider.overrideWithValue(merchants),
      suspectedDuplicateRepositoryProvider.overrideWithValue(suspected),
      userSettingsRepositoryProvider
          .overrideWithValue(DriftUserSettingsRepository(db)),
      ingestCapturedMessageUseCaseProvider.overrideWith((ref) => ingest),
      confirmTransactionUseCaseProvider
          .overrideWithValue(ConfirmTransactionUseCase(transactions)),
    ]);
    final coordinator = container.read(planningCutoverCoordinatorProvider)
        as DbBackedPlanningCutoverCoordinator;
    await coordinator.refreshFromDatabase();
    final rules = RulesClient(database: db); // local catalog reads only
    ingest = _ObservedIngest(
        AddTransactionUseCase(
          transactionRepository: transactions,
          merchantCategoryRepository: merchants,
          suspectedDuplicateRepository: suspected, accountRepository: accounts,
          dedupStore: DriftDedupStore(db), coordinator: coordinator,
          loadBankProfiles: ({String? senderId}) =>
              rules.localBankProfiles(senderId: senderId),
          loadCatalogRules: rules.catalogRulesForSender,
          // No real AI/discovery/enrichment client, install ID, metrics or sync queues.
          // Fail-closed constructor defaults preserve local/proof gates.
        ),
        key);
    _receipts.remove(key);
    if (!context.mounted) {
      await close();
      return false;
    }
    final fixture =
        _PasteBatchFixture(container, db, transactions, ingest, close);
    _active = fixture;
    visualParityPasteBatchConfirmOverlay.value = _PasteBatchHost(fixture);
    return true;
  } catch (_) {
    await close();
    rethrow;
  }
}

Future<void> closeVisualParityPasteBatchConfirm() async {
  final fixture = _active;
  if (fixture == null) return;
  visualParityPasteBatchConfirmOverlay.value = null;
  fixture.transactions.release();
  await Future<void>.delayed(Duration.zero);
  await fixture.close();
  if (identical(_active, fixture)) _active = null;
}

class _PasteBatchFixture {
  _PasteBatchFixture(
      this.container, this.db, this.transactions, this.ingest, this.close);
  final ProviderContainer container;
  final navigator = GlobalKey<NavigatorState>();
  final AppDatabase db;
  final _BatchTransactions transactions;
  final _ObservedIngest ingest;
  final Future<void> Function() close;
}

class _PasteBatchHost extends StatefulWidget {
  const _PasteBatchHost(this.fixture);
  final _PasteBatchFixture fixture;
  @override
  State<_PasteBatchHost> createState() => _PasteBatchHostState();
}

class _PasteBatchHostState extends State<_PasteBatchHost> {
  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
      container: widget.fixture.container,
      child: HeroControllerScope.none(
          child: Navigator(
              key: widget.fixture.navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const _PasteBatchLaunch()))));
}

class _PasteBatchLaunch extends StatefulWidget {
  const _PasteBatchLaunch();
  @override
  State<_PasteBatchLaunch> createState() => _PasteBatchLaunchState();
}

class _PasteBatchLaunchState extends State<_PasteBatchLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await ManualPasteScreen.showSheet(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
