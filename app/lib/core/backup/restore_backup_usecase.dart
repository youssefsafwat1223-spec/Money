import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';

class RestoreBackupUseCase {
  const RestoreBackupUseCase(this._db);

  final AppDatabase _db;

  static const _restoreOrder = [
    'merchants',
    'merchant_category_map',
    'transactions',
    'budgets',
    'goals',
    'goal_contributions',
    'achievements',
    'streaks',
    'user_settings',
    'subscriptions',
  ];

  static const _deleteOrder = [
    'subscriptions',
    'goal_contributions',
    'goals',
    'budgets',
    'transactions',
    'merchant_category_map',
    'merchants',
    'achievements',
    'streaks',
    'user_settings',
  ];

  Future<void> call(Map<String, dynamic> snapshot) async {
    final tables = snapshot['tables'] as Map<String, dynamic>;
    await _db.transaction(() async {
      await _db.customStatement('PRAGMA foreign_keys = OFF;');
      for (final table in _deleteOrder) {
        await _db.customStatement('DELETE FROM $table;');
      }
      for (final table in _restoreOrder) {
        final rows = (tables[table] as List<dynamic>?) ?? const [];
        for (final row in rows.cast<Map<String, dynamic>>()) {
          await _insertRow(table, row);
        }
      }
      await _db.customStatement('PRAGMA foreign_keys = ON;');
    });
  }

  Future<void> _insertRow(String table, Map<String, dynamic> row) async {
    final data = Map<String, dynamic>.from(row);
    if (table == 'transactions') {
      data['raw_message'] = '[restored: raw message intentionally excluded]';
    }
    final columns = data.keys.toList(growable: false);
    final placeholders = List.filled(columns.length, '?').join(', ');
    await _db.customInsert(
      'INSERT OR REPLACE INTO $table(${columns.join(', ')}) VALUES ($placeholders);',
      variables: <Variable>[
        for (final column in columns) _variable(data[column]),
      ],
    );
  }

  Variable _variable(Object? value) {
    if (value == null) return const Variable<String>(null);
    if (value is int) return Variable<int>(value);
    if (value is double) return Variable<double>(value);
    if (value is num) return Variable<double>(value.toDouble());
    return Variable<String>(value.toString());
  }
}
