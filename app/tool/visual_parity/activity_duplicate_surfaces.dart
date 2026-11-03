// Creates/removes one review flag on the disposable memory ledger only.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/suspected_duplicate_entity.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

Future<bool> openActivityDuplicateReview(
    BuildContext context, WidgetRef ref, {required bool clear}) async {
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('duplicate_review_requires_offline_debug');
  }
  final databases = await ref.read(appDatabaseProvider).customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('duplicate_review_requires_memory');
  }
  final repository = ref.read(suspectedDuplicateRepositoryProvider);
  final before = await repository.getAll();
  const id = 'qa-activity-review-flag';
  if (clear) {
    if (before.length != 1 || before.single.id != id) {
      throw StateError('duplicate_review_requires_own_flag');
    }
    await repository.delete(id);
    ref.invalidate(suspectedDuplicatesProvider);
    return true;
  }
  if (before.isNotEmpty) throw StateError('duplicate_review_requires_empty_flags');
  final transaction = await ref.read(transactionRepositoryProvider).getById('p-tx-0-0');
  if (transaction == null) throw StateError('duplicate_review_requires_fixture_transaction');
  await repository.save(SuspectedDuplicateEntity(
    id: id,
    rawMessage: transaction.rawMessage,
    existingTransactionId: transaction.id,
    amountMoney: transaction.amountMoney,
    currency: transaction.currency,
    rawMerchant: transaction.rawMerchant,
    occurredAt: transaction.occurredAt,
    createdAt: transaction.createdAt,
  ));
  ref.invalidate(suspectedDuplicatesProvider);
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => const TransactionsScreen(),
  )));
  return true;
}
