import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import 'backup_service.dart';

class RestoreBackupUseCase {
  const RestoreBackupUseCase(this._db);

  final AppDatabase _db;
  static const currentSchemaVersion = 3;

  // accounts must come before tables that FK into it; categories before the
  // rows that reference category_id (merchant_category_map, transactions,
  // budgets). sender_bank_mappings is independent.
  static const _restoreOrder = [
    'accounts',
    'categories',
    'cards',
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
    'sender_bank_mappings',
  ];

  // Delete in reverse FK order — children before parents.
  static const _deleteOrder = [
    'sender_bank_mappings',
    'plan_transaction_links',
    'plans',
    'bill_payments',
    'subscriptions',
    'goal_contributions',
    'goals',
    'budgets',
    'transactions',
    'merchant_category_map',
    'cards',
    'merchants',
    'achievements',
    'streaks',
    'user_settings',
    'categories',
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
    // Validate the WHOLE payload BEFORE any destructive DELETE runs, so a
    // malformed or truncated backup fails safely instead of half-wiping the
    // DB. A v3 backup with a missing/empty categories payload must be rejected
    // here — otherwise conditional-delete would wipe the catalog and restore
    // nothing.
    final tables = _validateSnapshot(snapshot, schemaVersion);
    await _db.transaction(() async {
      await _db.customStatement('PRAGMA foreign_keys = OFF;');
      // `PRAGMA foreign_keys` is connection-scoped, not part of the SQL
      // transaction — a thrown exception here still rolls back the row
      // changes (Drift's transaction()), but would otherwise leave FK
      // enforcement silently OFF for the rest of this DB connection's
      // lifetime unless restored in `finally`.
      try {
        for (final table in _deleteOrder) {
          // Conditional delete: only empty a table the backup actually carries
          // (back-compat). A v2 backup has no cards/categories/sender_mappings
          // keys, so its restore must NOT wipe the fresh DB's seeded catalog.
          if (!tables.containsKey(table)) continue;
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

  /// Structural preflight — runs before any DELETE. Rejects malformed/truncated
  /// backups so a bad file can never leave the DB half-restored, and refuses a
  /// v3 backup whose categories payload is missing/empty (which would let the
  /// conditional delete wipe the catalog with nothing to restore).
  Map<String, dynamic> _validateSnapshot(
    Map<String, dynamic> snapshot,
    int schemaVersion,
  ) {
    final rawTables = snapshot['tables'];
    if (rawTables is! Map<String, dynamic>) {
      throw const BackupException(
        'النسخة الاحتياطية تالفة أو غير مكتملة. تعذّرت الاستعادة.',
      );
    }
    // Every present table must be a list of row-maps.
    for (final entry in rawTables.entries) {
      final value = entry.value;
      if (value is! List) {
        throw BackupException(
          'النسخة الاحتياطية تالفة عند الجدول "${entry.key}". تعذّرت الاستعادة.',
        );
      }
      for (final row in value) {
        if (row is! Map<String, dynamic>) {
          throw BackupException(
            'النسخة الاحتياطية تالفة عند الجدول "${entry.key}". '
            'تعذّرت الاستعادة.',
          );
        }
      }
    }
    // v3+ must carry every REQUIRED table as a non-empty list. These three
    // always exist in a healthy DB (seeded catalog, ≥1 default account, the
    // single user_settings row), so their absence/emptiness signals a
    // truncated or corrupt backup — reject BEFORE any delete. (categories is
    // additionally load-bearing: the conditional delete would otherwise wipe
    // the catalog with nothing to restore.)
    if (schemaVersion >= 3) {
      for (final table in _requiredV3Tables) {
        final value = rawTables[table];
        if (value is! List || value.isEmpty) {
          throw BackupException(
            'النسخة الاحتياطية تالفة أو غير مكتملة (جدول "$table" مفقود). '
            'تعذّرت الاستعادة.',
          );
        }
      }
    }
    return rawTables;
  }

  /// Tables that a healthy v3 snapshot must always carry (non-empty). A
  /// truncated/corrupt backup missing any of these is rejected before the
  /// restore transaction. Everything else in the backup is optional (may be
  /// present but empty); tables outside the backup are intentionally excluded
  /// (see BackupSnapshotBuilder.intentionallyExcluded).
  static const _requiredV3Tables = {
    'categories',
    'accounts',
    'user_settings',
  };

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
