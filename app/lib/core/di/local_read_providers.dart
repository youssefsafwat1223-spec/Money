import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';
import '../i18n/locale_provider.dart';
import '../session/account_scope.dart';
import 'account_access_mode.dart';
import 'app_providers.dart' show appDatabaseProvider;

/// One account row of the read-only shell.
class LocalReadAccountRow {
  const LocalReadAccountRow(this.name, this.currency, this.balance);
  final String name;
  final String currency;
  final String balance;
}

/// One transaction row of the read-only shell.
class LocalReadTransactionRow {
  const LocalReadTransactionRow({
    required this.id,
    required this.title,
    required this.amount,
    required this.currency,
    required this.isDebit,
    required this.occurredAt,
  });
  final String id;
  final String title;
  final String amount;
  final String currency;
  final bool isDebit;
  final String occurredAt;
}

class LocalReadSnapshot {
  const LocalReadSnapshot(this.accounts, this.transactions);
  final List<LocalReadAccountRow> accounts;
  final List<LocalReadTransactionRow> transactions;
}

String _money(int minor, String currency) {
  final scale = isSupportedCurrency(currency) ? currencyScale(currency) : 2;
  return minorToDecimalString(minor, scale);
}

/// The existing accounts and the most recent transactions, SELECT only, straight
/// from the read-only handle. No repository, outbox, sync or write handler.
final localReadSnapshotProvider =
    FutureProvider.autoDispose<LocalReadSnapshot>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final accountRows = await db
      .customSelect('SELECT name, currency, current_balance_minor AS b '
          'FROM accounts WHERE deleted_at IS NULL '
          'ORDER BY sort_order, name;')
      .get();
  final txRows = await db
      .customSelect(
          'SELECT id, COALESCE(NULLIF(raw_merchant, \'\'), note, \'\') '
          'AS title, amount_minor AS a, currency, direction, occurred_at '
          'FROM transactions ORDER BY occurred_at DESC LIMIT 200;')
      .get();
  return LocalReadSnapshot([
    for (final r in accountRows)
      LocalReadAccountRow(
        r.read<String>('name'),
        r.read<String>('currency'),
        _money(r.readNullable<int>('b') ?? 0, r.read<String>('currency')),
      ),
  ], [
    for (final r in txRows)
      LocalReadTransactionRow(
        id: r.read<String>('id'),
        title: r.readNullable<String>('title') ?? '',
        amount: _money(r.read<int>('a'), r.read<String>('currency')),
        currency: r.read<String>('currency'),
        isDebit: r.readNullable<String>('direction') == 'debit',
        occurredAt: r.read<String>('occurred_at'),
      ),
  ]);
});

final _localReadLanguageProvider =
    FutureProvider.autoDispose<String?>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final rows = await db
      .customSelect('SELECT language FROM user_settings LIMIT 1;')
      .get();
  return rows.isEmpty ? null : rows.first.readNullable<String>('language');
});

/// Overrides for the provider graph of a local-read scope: the access mode, and
/// a language read straight from the read-only database (the ordinary locale
/// provider goes through the settings repository, a writer-bearing service).
List<Override> localReadProviderOverrides(AccountScope scope) => [
      accountAccessModeProvider.overrideWithValue(AccountAccessMode.localRead),
      localeProvider.overrideWith((ref) {
        final language = ref.watch(_localReadLanguageProvider).valueOrNull;
        return language == 'ar' ? const Locale('ar') : const Locale('en');
      }),
      // The ordinary one pushes the language into the notification service.
      notificationLanguageSyncProvider
          .overrideWith((ref) => ref.watch(localeProvider).languageCode),
    ];
