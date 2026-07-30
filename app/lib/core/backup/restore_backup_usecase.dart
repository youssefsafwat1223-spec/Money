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

    // MALI-045n: `PRAGMA foreign_keys` is connection-scoped and a documented
    // NO-OP while a transaction is pending, so it MUST be toggled OUTSIDE
    // _db.transaction() to genuinely suspend enforcement for the bulk restore.
    // (A self-consistent v3 snapshot — parents backed up FULL — would restore
    // fine with enforcement ON via the parent-before-child ordering; suspension
    // is retained only so legacy/cross-catalog backups restore gracefully
    // instead of failing on the first dangling reference.) After the inserts we
    // sanitize dangling references to satisfy the declared FK semantics, then
    // run `PRAGMA foreign_key_check` INSIDE the txn: any residual violation
    // throws and rolls the WHOLE restore back, leaving the original database
    // unchanged. `finally` re-enables enforcement no matter what.
    await _db.customStatement('PRAGMA foreign_keys = OFF;');
    try {
      await _db.transaction(() async {
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
        // Idempotent no-op for a self-consistent v3 snapshot; heals legacy /
        // cross-catalog dangling references so the committed DB is FK-clean.
        await _sanitizeDanglingReferences();
        // Postflight INSIDE the txn — a residual violation aborts + rolls back.
        final violations =
            await _db.customSelect('PRAGMA foreign_key_check;').get();
        if (violations.isNotEmpty) {
          throw const BackupException(
            'تعذّرت الاستعادة: النسخة الاحتياطية تنتهك سلامة العلاقات بين '
            'البيانات.',
          );
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON;');
    }
    // Enforcement MUST be back on for the rest of this connection's lifetime.
    final fkEnabled = (await _db.customSelect('PRAGMA foreign_keys;').getSingle())
        .read<int>('foreign_keys');
    if (fkEnabled != 1) {
      throw const BackupException(
        'تعذّر إعادة تفعيل قيود العلاقات بعد الاستعادة.',
      );
    }

    for (final step in _postRestoreMigrations) {
      if (step.appliesTo(schemaVersion)) {
        await step.run(_db);
      }
    }
  }

  /// FK-safe repair applied inside the restore transaction (with enforcement
  /// suspended). For a self-consistent v3 snapshot every statement matches zero
  /// rows. It heals legacy/cross-catalog inconsistencies (e.g. a v2 backup whose
  /// category ids don't exist on this install) so the committed database
  /// satisfies every declared foreign key: `SET NULL` references are nulled
  /// (matching ON DELETE SET NULL), and NOT-NULL child rows whose parent is
  /// genuinely absent are dropped in cascade-safe order (matching ON DELETE
  /// CASCADE) — orphan parents are removed before their own orphan children so
  /// no new dangling row is left behind.
  Future<void> _sanitizeDanglingReferences() async {
    // transactions.{category_id,merchant_id} — ON DELETE SET NULL.
    await _db.customStatement(
      'UPDATE transactions SET category_id = NULL '
      'WHERE category_id IS NOT NULL '
      'AND category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'UPDATE transactions SET merchant_id = NULL '
      'WHERE merchant_id IS NOT NULL '
      'AND merchant_id NOT IN (SELECT id FROM merchants);',
    );
    // NOT-NULL children invalid without their parent — drop (ON DELETE CASCADE).
    await _db.customStatement(
      'DELETE FROM merchant_category_map '
      'WHERE merchant_id NOT IN (SELECT id FROM merchants) '
      'OR category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'DELETE FROM budgets '
      'WHERE category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'DELETE FROM goal_contributions '
      'WHERE goal_id NOT IN (SELECT id FROM goals);',
    );
    // subscriptions.merchant_id is NOT NULL → drop an orphan subscription BEFORE
    // its bill_payments so the payment orphan check below then also fires.
    await _db.customStatement(
      'DELETE FROM subscriptions '
      'WHERE merchant_id NOT IN (SELECT id FROM merchants);',
    );
    await _db.customStatement(
      'DELETE FROM bill_payments '
      'WHERE bill_id NOT IN (SELECT id FROM subscriptions);',
    );
    await _db.customStatement(
      'DELETE FROM plan_transaction_links '
      'WHERE plan_id NOT IN (SELECT id FROM plans) '
      'OR transaction_id NOT IN (SELECT id FROM transactions);',
    );
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
