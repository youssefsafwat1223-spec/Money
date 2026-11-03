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
import 'package:money_companion/core/privacy/consent_authority.dart';
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
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';

const visualParityManualPasteResultKeys = [
  'manualPasteKnownAdded',
  'manualPastePendingReview',
  'manualPasteSuspectedDuplicate',
  'manualPasteOffline',
  'manualPasteAiOff',
];
const _known = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _unknown = 'عملية شراء\nمبلغ:SAR 82.00\n'
    'لدى:LOCAL ROASTER\nفي:2026-04-08 18:30';
String visualParityManualPasteMessage(String key) => switch (key) {
      'manualPastePendingReview' || 'manualPasteAiOff' => _unknown,
      'manualPasteOffline' => 'رمز التحقق الخاص بك هو 123456 ولا تشاركه مع أحد',
      _ => _known,
    };
final _events = <String, int>{};
Map<String, int> visualParityManualPasteResultEvents() =>
    Map.unmodifiable(_events);
// Actual returned result metadata only, never raw SMS, sender or notification
// fingerprint. This is not a SQL readback or a live authority/capability.
final _receipts = <String, Map<String, Object?>>{};
Map<String, Map<String, Object?>> visualParityManualPasteResultReceipts() =>
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

// A never-called transport sentinel, not an AI client implementation/result.
// Its presence lets the real use case check actual persisted denied consent.
class _DeniedAi implements AiParserClient {
  _DeniedAi(this.key);
  final String key;
  @override
  Future<AiParseResponse?> parse(
      {required String sanitizedSms,
      required String senderId,
      required String installId}) async {
    _record('${key}ForbiddenAiRequest');
    throw StateError('paste_result_ai_transport_forbidden');
  }
}

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'owned-paste-memory';
  @override
  Future<String?> readStoredKey() async => 'owned-paste-memory';
}

Future<bool> openVisualParityManualPasteResult(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityManualPasteResultKeys.contains(key)) return false;
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
    final transactions = DriftTransactionRepository(db);
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
    ]);
    final coordinator = container.read(planningCutoverCoordinatorProvider)
        as DbBackedPlanningCutoverCoordinator;
    await coordinator.refreshFromDatabase();
    final rules = RulesClient(database: db); // local catalog reads only
    final settings = DriftUserSettingsRepository(db);
    ingest = _ObservedIngest(
        AddTransactionUseCase(
          transactionRepository: transactions,
          merchantCategoryRepository: merchants,
          suspectedDuplicateRepository: suspected, accountRepository: accounts,
          dedupStore: DriftDedupStore(db), coordinator: coordinator,
          loadBankProfiles: ({String? senderId}) =>
              rules.localBankProfiles(senderId: senderId),
          loadCatalogRules: rules.catalogRulesForSender,
          aiClient: key == 'manualPasteAiOff' ? _DeniedAi(key) : null,
          loadAiConsent: key == 'manualPasteAiOff'
              ? () async {
                  _record('${key}ActualConsentRead');
                  return ConsentAuthority.decide(
                      EgressClass.aiProcessing, await settings.getSettings());
                }
              : null,
          // No real AI/discovery/enrichment client, install ID, metrics or sync queues.
          // Fail-closed constructor defaults preserve local/proof gates.
        ),
        key);
    _receipts.remove(key);
    if (key == 'manualPasteSuspectedDuplicate') {
      await ingest.fromCapturedMessage(CapturedMessage(
          text: _known,
          source: CapturedMessageSource.manualPaste,
          receivedAt: DateTime.utc(2026, 4, 8, 12, 45)));
    }
    if (!context.mounted) {
      await close();
      return false;
    }
    final owned = container;
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
            builder: (_) => _Lifetime(
                close: close,
                child: UncontrolledProviderScope(
                    container: owned,
                    child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (_) => _PasteHost(
                                ingest: ingest,
                                closeOuter: () {
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                })))))))
        .whenComplete(close));
    return true;
  } catch (_) {
    await close();
    rethrow;
  }
}

class _Lifetime extends StatefulWidget {
  const _Lifetime({required this.close, required this.child});
  final Future<void> Function() close;
  final Widget child;
  @override
  State<_Lifetime> createState() => _LifetimeState();
}

class _LifetimeState extends State<_Lifetime> {
  @override
  void dispose() {
    unawaited(widget.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PasteHost extends StatefulWidget {
  const _PasteHost({required this.ingest, required this.closeOuter});
  final _ObservedIngest ingest;
  final VoidCallback closeOuter;
  @override
  State<_PasteHost> createState() => _PasteHostState();
}

class _PasteHostState extends State<_PasteHost> {
  Future<void>? review;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ManualPasteScreen.showSheet(context, onTransactionAdded: (id) {
        final result = widget.ingest.latest!.addTransactionResult;
        if (result.transaction?.id != id ||
            result.outcome != AddTransactionOutcome.added) {
          throw StateError('paste_result_host_requires_actual_saved_id');
        }
        _record('${widget.ingest.key}ActualHostReview');
        // Documented public host integration keeps the actual saved row and
        // public review modal inside this owned navigator/repository scope.
        review = showConfirmTransactionSheet(context, id,
            secondaryNotice: pasteAnalysisNotice(context, result));
      });
      await review;
      if (mounted) widget.closeOuter();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Isolated local capture QA')));
}
