import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

Map<String, dynamic>? _decodeMetadata(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

AccountEntity accountFromRow(QueryRow row) {
  return AccountEntity(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    currency: row.read<String>('currency'),
    type: accountTypeFromKey(row.read<String>('type')),
    initialBalance: row.readNullable<double>('initial_balance'),
    currentBalance: row.readNullable<double>('current_balance'),
    bankAccountNumber: row.readNullable<String>('bank_account_number'),
    creditLimit: row.readNullable<double>('credit_limit'),
    availableCredit: row.readNullable<double>('available_credit'),
    paymentDueDay: row.readNullable<int>('payment_due_day'),
    walletProvider: row.readNullable<String>('wallet_provider'),
    excludeFromTotals: sqlToBool(row.read<int>('exclude_from_totals')),
    metadata: _decodeMetadata(row.readNullable<String>('metadata')),
    isDefault: sqlToBool(row.read<int>('is_default')),
    sortOrder: row.read<int>('sort_order'),
    createdAt: dateTimeFromSql(row.read<String>('created_at')),
    updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
  );
}

List<Variable> _accountFieldVars(AccountEntity account) => [
      account.bankAccountNumber == null
          ? const Variable<String>(null)
          : Variable.withString(account.bankAccountNumber!),
      account.creditLimit == null
          ? const Variable<double>(null)
          : Variable.withReal(account.creditLimit!),
      account.availableCredit == null
          ? const Variable<double>(null)
          : Variable.withReal(account.availableCredit!),
      account.paymentDueDay == null
          ? const Variable<int>(null)
          : Variable.withInt(account.paymentDueDay!),
      account.walletProvider == null
          ? const Variable<String>(null)
          : Variable.withString(account.walletProvider!),
      Variable.withInt(boolToSql(account.excludeFromTotals)),
      account.metadata == null
          ? const Variable<String>(null)
          : Variable.withString(jsonEncode(account.metadata)),
    ];

class DriftAccountRepository implements AccountRepository {
  DriftAccountRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
  }) : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<List<AccountEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM accounts WHERE deleted_at IS NULL '
          'ORDER BY is_default DESC, sort_order ASC, created_at ASC;',
        )
        .get();
    return rows.map(accountFromRow).toList();
  }

  @override
  Future<AccountEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM accounts WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : accountFromRow(row);
  }

  @override
  Future<AccountEntity?> getDefault() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM accounts WHERE deleted_at IS NULL '
          'ORDER BY is_default DESC, sort_order ASC LIMIT 1;',
        )
        .getSingleOrNull();
    return row == null ? null : accountFromRow(row);
  }

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    return _db.transaction(() async {
      final id = account.id.isEmpty ? IdGenerator.next() : account.id;
      final now = DateTime.now().toUtc();
      final isFirst = (await _activeAccountCount()) == 0;
      final makeDefault = account.isDefault || isFirst;
      final previousDefaults =
          makeDefault ? await _defaultAccounts() : <AccountEntity>[];
      if (makeDefault) {
        await _db.customStatement(
          'UPDATE accounts SET is_default = 0 WHERE deleted_at IS NULL;',
        );
      }
      await _db.customInsert(
        '''
        INSERT INTO accounts(
          id, name, currency, type, initial_balance, current_balance,
          bank_account_number, credit_limit, available_credit,
          payment_due_day, wallet_provider, exclude_from_totals, metadata,
          is_default, sort_order, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
        variables: [
          Variable.withString(id),
          Variable.withString(account.name),
          Variable.withString(account.currency),
          Variable.withString(account.type.name),
          account.initialBalance == null
              ? const Variable<double>(null)
              : Variable.withReal(account.initialBalance!),
          account.currentBalance == null
              ? const Variable<double>(null)
              : Variable.withReal(account.currentBalance!),
          ..._accountFieldVars(account),
          Variable.withInt(boolToSql(makeDefault)),
          Variable.withInt(account.sortOrder),
          Variable.withString(dateTimeToSql(now)),
          Variable.withString(dateTimeToSql(now)),
        ],
      );
      final saved = await getById(id);
      for (final previous in previousDefaults) {
        final updated = await getById(previous.id);
        if (updated != null) {
          await _outboxQueue?.enqueueAccount(
            PlanningSyncOperation.update,
            updated,
          );
        }
      }
      if (saved != null) {
        await _outboxQueue?.enqueueAccount(PlanningSyncOperation.create, saved);
      }
      return saved!;
    });
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async {
    return _db.transaction(() async {
      await _db.customUpdate(
        '''
        UPDATE accounts
        SET name = ?, currency = ?, type = ?, initial_balance = ?,
            current_balance = ?, bank_account_number = ?, credit_limit = ?,
            available_credit = ?, payment_due_day = ?, wallet_provider = ?,
            exclude_from_totals = ?, metadata = ?, sort_order = ?, updated_at = ?
        WHERE id = ?;
      ''',
        variables: [
          Variable.withString(account.name),
          Variable.withString(account.currency),
          Variable.withString(account.type.name),
          account.initialBalance == null
              ? const Variable<double>(null)
              : Variable.withReal(account.initialBalance!),
          account.currentBalance == null
              ? const Variable<double>(null)
              : Variable.withReal(account.currentBalance!),
          ..._accountFieldVars(account),
          Variable.withInt(account.sortOrder),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(account.id),
        ],
      );
      final saved = await getById(account.id);
      if (saved == null) {
        throw StateError('Account not found: ${account.id}');
      }
      await _outboxQueue?.enqueueAccount(PlanningSyncOperation.update, saved);
      return saved;
    });
  }

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      final account = await getById(id);
      if (account == null) return;
      // لا نحذف آخر حساب.
      if ((await _activeAccountCount()) <= 1) {
        throw StateError('Cannot delete the last account.');
      }
      // فُكّ ربط عملياته (تبقى محفوظة بلا حساب).
      await _db.customStatement(
        'UPDATE transactions SET account_id = NULL WHERE account_id = ${sqlString(id)};',
      );
      await _db.customStatement(
        'UPDATE accounts SET deleted_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}, '
        'is_default = 0 WHERE id = ${sqlString(id)};',
      );
      if (account.isDefault) {
        await _db.customStatement(
          'UPDATE accounts SET is_default = 1 WHERE id = '
          '(SELECT id FROM accounts WHERE deleted_at IS NULL '
          'ORDER BY sort_order ASC LIMIT 1);',
        );
        // The promoted successor must reach the server too (MALI-015):
        // without this enqueue a fresh device pulled no default at all.
        final successor = await getDefault();
        if (successor != null) {
          await _outboxQueue?.enqueueAccount(
            PlanningSyncOperation.update,
            successor,
          );
        }
      }
      await _outboxQueue?.enqueueAccount(PlanningSyncOperation.delete, account);
    });
  }

  @override
  Future<void> setDefault(String id) async {
    await _db.transaction(() async {
      await _db.customStatement(
        'UPDATE accounts SET is_default = 0 WHERE deleted_at IS NULL;',
      );
      await _db.customUpdate(
        'UPDATE accounts SET is_default = 1 WHERE id = ? AND deleted_at IS NULL;',
        variables: [Variable.withString(id)],
      );
      for (final account in await getAll()) {
        await _outboxQueue?.enqueueAccount(
          PlanningSyncOperation.update,
          account,
        );
      }
    });
  }

  Future<int> _activeAccountCount() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM accounts WHERE deleted_at IS NULL;',
        )
        .getSingle();
    return row.read<int>('total');
  }

  Future<List<AccountEntity>> _defaultAccounts() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM accounts WHERE deleted_at IS NULL AND is_default = 1;',
        )
        .get();
    return rows.map(accountFromRow).toList();
  }
}
