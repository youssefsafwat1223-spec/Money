// Offline QA only. Real pending rows, no successful confirmation or authority.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';

const visualParityConfirmationOutcomeKeys = ['confirmationSaving', 'confirmationError'];
const visualParityConfirmationTransactionId = 'p-tx-pending-0';
final _events = <String, int>{};
Map<String, int> visualParityConfirmationOutcomeEvents() => Map.unmodifiable(_events);

class _ConfirmationRepository extends DriftTransactionRepository {
  _ConfirmationRepository(super.database, this.key);
  final String key;
  @override
  Future<TransactionEntity> confirm(String id) {
    if (id != visualParityConfirmationTransactionId) {
      throw StateError('confirmation_visual_unexpected_transaction');
    }
    _events.update(key, (count) => count + 1, ifAbsent: () => 1);
    return key == 'confirmationSaving'
        ? Completer<TransactionEntity>().future
        : Future<TransactionEntity>.error(StateError('private_confirmation_visual_failure'));
  }
}

Future<bool> openVisualParityConfirmationOutcome(BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityConfirmationOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('confirmation_visual_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) => r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('confirmation_visual_requires_memory_database');
  }
  final tx = await ref.read(transactionRepositoryProvider).getById(visualParityConfirmationTransactionId);
  if (tx == null || tx.status != TransactionStatus.pending ||
      tx.pricingState == TransactionPricingState.awaitingFx || tx.amountMoney.minorUnits <= 0) {
    throw StateError('confirmation_visual_requires_existing_priced_pending_row');
  }
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => _ConfirmationScope(database: db, keyName: key, locale: Localizations.localeOf(context)),
  )));
  return true;
}

class _ConfirmationScope extends StatefulWidget {
  const _ConfirmationScope({required this.database, required this.keyName, required this.locale});
  final AppDatabase database;
  final String keyName;
  final Locale locale;
  @override
  State<_ConfirmationScope> createState() => _ConfirmationScopeState();
}

class _ConfirmationScopeState extends State<_ConfirmationScope> {
  late final ProviderContainer _container;
  @override
  void initState() {
    super.initState();
    final repository = _ConfirmationRepository(widget.database, widget.keyName);
    // Separate provider root avoids inherited cached transaction providers;
    // every read remains the actual Drift repository on the same memory DB.
    _container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(widget.database),
      localeProvider.overrideWithValue(widget.locale),
      transactionRepositoryProvider.overrideWithValue(repository),
      confirmTransactionUseCaseProvider.overrideWithValue(ConfirmTransactionUseCase(repository)),
    ]);
  }
  @override
  void dispose() { _container.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: _container,
    child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const _ConfirmationHost())),
  );
}

class _ConfirmationHost extends StatefulWidget {
  const _ConfirmationHost();
  @override
  State<_ConfirmationHost> createState() => _ConfirmationHostState();
}
class _ConfirmationHostState extends State<_ConfirmationHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showConfirmTransactionSheet(context, visualParityConfirmationTransactionId);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }
  @override
  Widget build(BuildContext context) => const Scaffold();
}
