import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import 'backup_service.dart';

class RestoreBackupUseCase {
  const RestoreBackupUseCase(this._db);

  final AppDatabase _db;
  static const currentSchemaVersion = 2;

  // accounts must come before tables that FK into it.
  static const _restoreOrder = [
    'accounts',
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
    'bill_payments',
    'plans',
    'plan_transaction_links',
  ];

  // Delete in reverse FK order — children before parents.
  static const _deleteOrder = [
    'plan_transaction_links',
    'plans',
    'bill_payments',
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
    'accounts',
  ];

  Future<void> call(Map<String, dynamic> snapshot) async {
    final schemaVersion = _schemaVersion(snapshot);
    if (schemaVersion > currentSchemaVersion) {
      // Reject BEFORE touching the DB — the delete/restore transaction below
      // must never start against a backup this app build doesn't know how
      // to fully apply (a newer backup format may reference columns/tables
      // this build hasn't created yet, and skipping unknown post-restore
      // migrations would leave the DB silently half-migrated).
      throw const BackupException(
        'هذه النسخة الاحتياطية من إصدار أحدث من التطبيق. حدّث التطبيق ثم '
        'أعد المحاولة.',
      );
    }
    final tables = snapshot['tables'] as Map<String, dynamic>;
    await _db.transaction(() async {
      await _db.customStatement('PRAGMA foreign_keys = OFF;');
      // `PRAGMA foreign_keys` is connection-scoped, not part of the SQL
      // transaction — a thrown exception here still rolls back the row
      // changes (Drift's transaction()), but would otherwise leave FK
      // enforcement silently OFF for the rest of this DB connection's
      // lifetime unless restored in `finally`.
      try {
        for (final table in _deleteOrder) {
          await _db.customStatement('DELETE FROM $table;');
        }
        for (final table in _restoreOrder) {
          final rows = (tables[table] as List<dynamic>?) ?? const [];
          for (final row in rows.cast<Map<String, dynamic>>()) {
            await _insertRow(table, row);
          }
        }
      } finally {
        await _db.customStatement('PRAGMA foreign_keys = ON;');
      }
    });

    for (final step in _postRestoreMigrations) {
      if (step.appliesTo(schemaVersion)) {
        await step.run(_db);
      }
    }
  }

  int _schemaVersion(Map<String, dynamic> snapshot) {
    final value = snapshot['schemaVersion'];
    if (value is int && value > 0) return value;
    return 1;
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

class _PostRestoreMigration {
  const _PostRestoreMigration({
    required this.fromInclusive,
    required this.toInclusive,
    required this.run,
  });

  final int fromInclusive;
  final int toInclusive;
  final Future<void> Function(AppDatabase db) run;

  bool appliesTo(int schemaVersion) =>
      schemaVersion >= fromInclusive && schemaVersion <= toInclusive;
}

final _postRestoreMigrations = <_PostRestoreMigration>[
  _PostRestoreMigration(
    fromInclusive: 1,
    toInclusive: RestoreBackupUseCase.currentSchemaVersion,
    run: (db) => db.runPostRestoreSetup(),
  ),
];
