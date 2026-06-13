import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

AccountEntity accountFromRow(QueryRow row) {
  return AccountEntity(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    currency: row.read<String>('currency'),
    type: accountTypeFromKey(row.read<String>('type')),
    initialBalance: row.readNullable<double>('initial_balance'),
    currentBalance: row.readNullable<double>('current_balance'),
    isDefault: sqlToBool(row.read<int>('is_default')),
    sortOrder: row.read<int>('sort_order'),
    createdAt: dateTimeFromSql(row.read<String>('created_at')),
    updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
  );
}

class DriftAccountRepository implements AccountRepository {
  DriftAccountRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<AccountEntity>> getAll() async {
    final rows = await _db.customSelect(
      'SELECT * FROM accounts ORDER BY is_default DESC, sort_order ASC, created_at ASC;',
    ).get();
    return rows.map(accountFromRow).toList();
  }

  @override
  Future<AccountEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM accounts WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : accountFromRow(row);
  }

  @override
  Future<AccountEntity?> getDefault() async {
    final row = await _db.customSelect(
      'SELECT * FROM accounts ORDER BY is_default DESC, sort_order ASC LIMIT 1;',
    ).getSingleOrNull();
    return row == null ? null : accountFromRow(row);
  }

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    final id = account.id.isEmpty ? IdGenerator.next() : account.id;
    final now = DateTime.now().toUtc();
    final isFirst = (await _db.count('accounts')) == 0;
    final makeDefault = account.isDefault || isFirst;
    if (makeDefault) {
      await _db.customStatement('UPDATE accounts SET is_default = 0;');
    }
    await _db.customInsert(
      '''
        INSERT INTO accounts(
          id, name, currency, type, initial_balance, current_balance,
          is_default, sort_order, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        Variable.withInt(boolToSql(makeDefault)),
        Variable.withInt(account.sortOrder),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
      ],
    );
    final saved = await getById(id);
    return saved!;
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async {
    await _db.customUpdate(
      '''
        UPDATE accounts
        SET name = ?, currency = ?, type = ?, initial_balance = ?,
            current_balance = ?, sort_order = ?, updated_at = ?
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
        Variable.withInt(account.sortOrder),
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(account.id),
      ],
    );
    final saved = await getById(account.id);
    if (saved == null) {
      throw StateError('Account not found: ${account.id}');
    }
    return saved;
  }

  @override
  Future<void> delete(String id) async {
    final account = await getById(id);
    if (account == null) return;
    // لا نحذف آخر حساب.
    if ((await _db.count('accounts')) <= 1) {
      throw StateError('Cannot delete the last account.');
    }
    // فُكّ ربط عملياته (تبقى محفوظة بلا حساب).
    await _db.customStatement(
      'UPDATE transactions SET account_id = NULL WHERE account_id = ${sqlString(id)};',
    );
    await _db.customStatement(
      'DELETE FROM accounts WHERE id = ${sqlString(id)};',
    );
    if (account.isDefault) {
      await _db.customStatement(
        'UPDATE accounts SET is_default = 1 WHERE id = '
        '(SELECT id FROM accounts ORDER BY sort_order ASC LIMIT 1);',
      );
    }
  }

  @override
  Future<void> setDefault(String id) async {
    await _db.customStatement('UPDATE accounts SET is_default = 0;');
    await _db.customUpdate(
      'UPDATE accounts SET is_default = 1 WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }
}
