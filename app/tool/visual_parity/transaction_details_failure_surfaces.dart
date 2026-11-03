// Offline, negative-only QA. Never imported by the application entry point.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';

const visualParityTransactionFailureKeys = ['transactionConfirmFailure', 'transactionDeleteFailure'];
final _events = <String, int>{};
Map<String, int> visualParityTransactionFailureEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
FailureOnlyTransactionRepository? _active;
void releaseVisualParityTransactionFailure() => _active?.release();

class FailureOnlyTransactionRepository extends DriftTransactionRepository {
  FailureOnlyTransactionRepository(super.db, {required this.id, required this.delete, this.network = false});
  final String id;
  final bool delete, network;
  final gate = Completer<void>();
  int calls = 0;
  void release() { if (!gate.isCompleted) gate.complete(); }
  Future<Never> _fail(String target, bool deleting) async {
    if (id != target || delete != deleting) throw StateError('unexpected_transaction_failure_action');
    calls++;
    _event(delete ? 'transactionDeleteFailureAdmitted' : 'transactionConfirmFailureAdmitted');
    await gate.future;
    if (network) throw const NetworkRepoException('private_synthetic_transaction_network');
    throw StateError('private_synthetic_transaction_failure_before_write');
  }
  @override Future<TransactionEntity> confirm(String id) => _fail(id, false);
  @override Future<void> deleteTransaction(String id) => _fail(id, true);
}

Future<bool> openVisualParityTransactionFailure(BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityTransactionFailureKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) throw StateError('transaction_failure_requires_offline_debug');
  if (ref.read(accountAccessModeProvider) != AccountAccessMode.writable) throw StateError('transaction_failure_requires_writable_memory');
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) => r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('transaction_failure_requires_memory');
  }
  final transactions = await ref.read(transactionRepositoryProvider).getPage(offset: 0, limit: 100);
  final pending = transactions.where((t) => t.status == TransactionStatus.pending).toList();
  if (pending.isEmpty) throw StateError('transaction_failure_requires_actual_pending_row');
  if (!context.mounted) return false;
  final repository = FailureOnlyTransactionRepository(db, id: pending.first.id, delete: key == 'transactionDeleteFailure');
  final container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db), transactionRepositoryProvider.overrideWithValue(repository)]);
  _active = repository; _event('${key}Opened');
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => UncontrolledProviderScope(container: container, child: TransactionDetailsScreen(transactionId: pending.first.id)))).whenComplete(() {
    repository.release(); if (identical(_active, repository)) _active = null;
    container.dispose(); _event('${key}Closed');
  }));
  return true;
}
