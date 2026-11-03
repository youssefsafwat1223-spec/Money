// Offline QA: actual pending-transaction ages on a fresh owned memory database.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';

const visualParityPendingAgeKeys = ['pendingAgeToday', 'pendingAgeFiveDays'];
final _events = <String, int>{};
Map<String, int> visualParityPendingAgeEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'pending-age-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'pending-age-owned-memory';
}

Future<bool> openVisualParityPendingAge(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityPendingAgeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('pending_age_requires_offline_debug');
  }
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('pending_age_requires_memory_parent');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  Future<void>? closing;
  Future<void> close() => closing ??= (() async {
        container?.dispose();
        await db.close();
        _event('${key}Closed');
      })();
  try {
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
    ]);
    final now = DateTime.now().toUtc();
    final created =
        key == 'pendingAgeToday' ? now : now.subtract(const Duration(days: 5));
    final account = await container.read(accountRepositoryProvider).create(
        AccountEntity(
            id: 'qa-pending-age-account',
            name: 'QA KWD account',
            currency: 'KWD',
            type: AccountType.bank,
            isDefault: true,
            sortOrder: 0,
            createdAt: created,
            updatedAt: created,
            initialBalanceMoney: Money.zero('KWD'),
            currentBalanceMoney: Money.zero('KWD')));
    await container.read(transactionRepositoryProvider).saveTransaction(
        transaction: TransactionEntity(
            id: 'qa-pending-age-transaction',
            accountId: account.id,
            amountMoney: Money(12345, 'KWD'),
            currency: 'KWD',
            type: TransactionTypeEntity.payment,
            source: TransactionSourceEntity.imported,
            occurredAt: created,
            createdAt: created,
            updatedAt: created,
            rawMessage: 'Synthetic pending age example',
            rawMerchant: 'QA market',
            parseConfidence: .6,
            status: TransactionStatus.pending,
            direction: TransactionDirectionEntity.debit),
        categoryKey: 'groceries');
    if (!context.mounted) {
      await close();
      return false;
    }
    final owned = container;
    _event('${key}Opened');
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
            builder: (_) => _Lifetime(
                close: close,
                child: UncontrolledProviderScope(
                    container: owned,
                    child: const TransactionDetailsScreen(
                        transactionId: 'qa-pending-age-transaction')))))
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
