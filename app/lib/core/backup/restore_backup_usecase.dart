import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import '../../domain/finance/financial_semantics.dart';
import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

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

  /// Apply [snapshot] destructively. When [plan] is supplied (Batch-5 pipeline),
  /// an in-transaction verification runs against it before commit, so any
  /// row-count / financial-total / integrity mismatch rolls the WHOLE restore back
  /// and leaves the original database unchanged.
  Future<void> call(Map<String, dynamic> snapshot, {RestorePlan? plan}) async {
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
    final tables = validateTables(snapshot, schemaVersion);

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
        // MALI-014/076n §6 — in-transaction verification against the immutable
        // plan. Any mismatch throws BEFORE commit → the whole restore rolls back
        // and the original database is preserved.
        if (plan != null) await _verifyAgainstPlan(plan);
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

  /// MALI-014/076n §6 — verify the freshly-written (uncommitted) database state
  /// against the immutable plan. Throws [RestoreVerificationException] on any
  /// mismatch so the transaction rolls back before commit. Runs INSIDE the restore
  /// transaction. No data is surfaced — only protocol labels.
  Future<void> _verifyAgainstPlan(RestorePlan plan) async {
    Future<int> count(String table) async {
      final row = await _db
          .customSelect('SELECT COUNT(*) AS c FROM $table;')
          .getSingle();
      return row.read<int>('c');
    }

    // (1) Required singleton — the single user_settings row must exist.
    if (await count('user_settings') != 1) {
      throw const RestoreVerificationException('missing_singleton');
    }

    // (2) Transactions are never sanitized away, so their count must match the
    // plan exactly; and no duplicate primary id may exist (INSERT OR REPLACE
    // dedupes, so a mismatch means the plan itself carried duplicates).
    final expectedTxns = plan.expectedRowCounts['transactions'] ?? 0;
    final actualTxns = await count('transactions');
    if (actualTxns != expectedTxns) {
      throw const RestoreVerificationException('row_count_mismatch');
    }
    final distinctTxnIds = (await _db
            .customSelect('SELECT COUNT(DISTINCT id) AS c FROM transactions;')
            .getSingle())
        .read<int>('c');
    if (distinctTxnIds != actualTxns) {
      throw const RestoreVerificationException('duplicate_identifier');
    }

    // (3) Tables that CAN be sanitized (orphans dropped) must never have MORE rows
    // than the plan — more rows means a stray insert leaked in.
    for (final entry in plan.expectedRowCounts.entries) {
      if (entry.key == 'transactions') continue;
      if (await count(entry.key) > entry.value) {
        throw const RestoreVerificationException('row_count_mismatch');
      }
    }

    // (4) Financial fidelity — the canonical net-expense confirmed total computed
    // over the RESTORED transactions must equal the total computed over the PLAN's
    // transactions (Phase-4 semantics). A silent value corruption fails here.
    final restoredTotal = (await _db
            .customSelect(
              'SELECT COALESCE(SUM(${FinancialSql.netExpenseSignedAmount()}), 0) AS t '
              'FROM transactions WHERE ${FinancialSql.confirmedPredicate()};',
            )
            .getSingle())
        .read<double>('t');
    final planTotal = _planNetExpenseTotal(plan);
    if ((restoredTotal - planTotal).abs() > 1e-6) {
      throw const RestoreVerificationException('total_mismatch');
    }

    // (5) No SQLCipher key reference may survive the restore.
    final keyRef = (await _db
            .customSelect(
                "SELECT COALESCE(db_encryption_key_ref, '') AS k FROM user_settings LIMIT 1;")
            .getSingle())
        .read<String>('k');
    if (keyRef.isNotEmpty) {
      throw const RestoreVerificationException('key_ref_present');
    }

    // (6) No intentionally-excluded (remote/pending relay/cache) table may be in
    // the plan — those must never be restored.
    for (final table in plan.tables.keys) {
      if (BackupSnapshotBuilder.intentionallyExcluded.contains(table)) {
        throw const RestoreVerificationException('remote_row_present');
      }
    }
  }

  /// Canonical net-expense confirmed total over the plan's transaction rows
  /// (refund subtracts; payment/withdrawal add; confirmed only) — mirrors
  /// [FinancialSql.netExpenseSignedAmount] + [FinancialSql.confirmedPredicate].
  double _planNetExpenseTotal(RestorePlan plan) {
    var total = 0.0;
    for (final row in plan.tables['transactions'] ?? const []) {
      if (row['status'] != 'confirmed') continue;
      final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
      switch (row['type']) {
        case 'refund':
          total -= amount;
        case 'payment':
        case 'withdrawal':
          total += amount;
      }
    }
    return total;
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
  static Map<String, dynamic> validateTables(
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
        // MALI-058n §4/§6 — fail CLOSED on an unexpected key/secret-like field
        // BEFORE any destructive step. The one known-deprecated field
        // (db_encryption_key_ref from a legacy snapshot) is tolerated — it is
        // dropped on insert, so an otherwise-valid legacy backup still restores.
        // Any OTHER security-sensitive column outside the backup-safe whitelist
        // is rejected, so a tampered/foreign snapshot can never smuggle key
        // material (or a mismatched location) into the restored database.
        final allowed = BackupSnapshotBuilder.restorableColumns[entry.key];
        for (final key in row.keys) {
          if (allowed != null && allowed.contains(key)) continue;
          if (_knownDeprecatedColumns.contains(key)) continue;
          if (_looksSensitive(key)) {
            throw BackupException(
              'النسخة الاحتياطية تحتوي على حقل حسّاس غير متوقع '
              '("${entry.key}"). تعذّرت الاستعادة.',
            );
          }
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

  // MALI-058n §3/§7 — a legacy snapshot may carry the deprecated raw-key column;
  // it is never written to the destination DB.
  static const _knownDeprecatedColumns = {'db_encryption_key_ref'};

  // Any snapshot column outside the backup-safe whitelist whose NAME looks like
  // key/secret material and is not a known-deprecated field → fail closed.
  static final _sensitivePattern = RegExp(
    r'(?:^|_)(key|secret|token|password|passphrase|credential|cipher)(?:$|_)',
    caseSensitive: false,
  );
  static bool _looksSensitive(String column) =>
      _sensitivePattern.hasMatch(column);

  Future<void> _insertRow(String table, Map<String, dynamic> row) async {
    final data = Map<String, dynamic>.from(row);
    if (table == 'transactions') {
      data['raw_message'] = '[restored: raw message intentionally excluded]';
    }
    if (table == 'user_settings') {
      // MALI-058n §4 — the deprecated key column is NOT NULL, so the restore
      // must write it, but it writes ONLY '' — never the (possibly key-bearing)
      // value a legacy/foreign snapshot may carry.
      data['db_encryption_key_ref'] = '';
    }
    // MALI-058n §6 — column names are fixed by application code, NEVER taken
    // from arbitrary snapshot keys. Restrict to the backup-safe whitelist; any
    // other key (a legacy db_encryption_key_ref value, or any unrecognized
    // field) is dropped here and never reaches the SQL or the destination DB.
    final allowed = BackupSnapshotBuilder.restorableColumns[table];
    if (allowed == null) {
      // A restore-order table must have a defined whitelist — refuse to build
      // SQL from arbitrary identifiers rather than trust the snapshot.
      throw BackupException(
        'تعذّرت الاستعادة: جدول غير مدعوم ("$table").',
      );
    }
    final restorable = <String>{
      ...allowed,
      if (table == 'transactions') 'raw_message',
      // Written as '' above; included so the NOT NULL column is satisfied.
      if (table == 'user_settings') 'db_encryption_key_ref',
    };
    final columns = [
      for (final column in restorable)
        if (data.containsKey(column)) column,
    ];
    if (columns.isEmpty) return;
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
