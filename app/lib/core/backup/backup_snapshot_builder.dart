import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';
import 'backup_crypto.dart' show BackupEnvelopeException, BackupEnvelopeErrorKind;

class BackupSnapshotBuilder {
  const BackupSnapshotBuilder(this._db);

  final AppDatabase _db;
  // v3 (MALI-014): adds cards, categories (full-fidelity incl. soft-deleted),
  // user-learned sender_bank_mappings, and the previously-omitted account
  // columns. Reads run in one snapshot transaction. v2 backups still restore.
  static const currentSchemaVersion = 3;

  static const _tables = <String, List<String>>{
    'accounts': [
      'id',
      'name',
      'currency',
      'type',
      'initial_balance',
      'current_balance',
      'bank_account_number',
      'credit_limit',
      'available_credit',
      'payment_due_day',
      'wallet_provider',
      'exclude_from_totals',
      'metadata',
      'is_default',
      'sort_order',
      'created_at',
      'updated_at',
    ],
    'transactions': [
      'id',
      'account_id',
      'amount',
      'currency',
      'merchant_id',
      'raw_merchant',
      'category_id',
      'type',
      'source',
      'card_last4',
      'balance_after',
      'note',
      'occurred_at',
      'parse_confidence',
      'status',
      'created_at',
      'updated_at',
      'foreign_amount',
      'foreign_currency',
      'direction',
      'transaction_time_from_sms',
      'sms_received_at',
      'comparison_timestamp',
      'comparison_timestamp_source',
      'duplicate_status',
      'possible_duplicate_of_transaction_id',
      'duplicate_reason',
    ],
    'budgets': [
      'id',
      'account_id',
      'category_id',
      'amount',
      'period',
      'start_date',
      'is_active',
      'last_notified_spent_amount',
      'last_notified_period_start',
      'show_on_header',
    ],
    'goals': [
      'id',
      'account_id',
      'name',
      'target_amount',
      'saved_amount',
      'deadline',
      'vault_skin',
      'status',
      'created_at',
      'auto_save_amount',
      'auto_save_period',
      'auto_save_last_run',
      'last_notified_saved_amount',
      'deleted_at',
    ],
    'goal_contributions': [
      'id',
      'goal_id',
      'amount',
      'created_at',
      'note',
    ],
    'merchant_category_map': [
      'id',
      'merchant_id',
      'category_id',
      'is_user_confirmed',
      'confidence',
      'updated_at',
    ],
    'merchants': [
      'id',
      'raw_name',
      'normalized_name',
      'first_seen_at',
      'last_seen_at',
    ],
    'achievements': [
      'id',
      'key',
      'name_ar',
      'unlocked_at',
      'progress',
    ],
    'streaks': [
      'id',
      'current_streak',
      'longest_streak',
      'last_active_date',
      'freezes_available',
    ],
    // Backup-safe user_settings columns (MALI-058n). Each is user-authored,
    // owned by the single local user, portable across the user's devices, and
    // safe to restore; an absent value falls back to the column default on the
    // destination. EXCLUDED, deliberately: db_encryption_key_ref (the local
    // SQLCipher key is device-scoped platform-secure-storage material and must
    // never enter a snapshot — MALI-058n); consent columns (ai_consent_granted /
    // cloud_processing_enabled + versioned *_state — a restore must never import
    // consent as authorization, MALI-059n; runPostRestoreSetup resets them OFF).
    //   id                 — the settings row id (stable per install)
    //   display_name       — user profile name
    //   phone_number       — user profile phone
    //   avatar_path        — local avatar file reference
    //   date_of_birth      — user profile DOB
    //   country / currency / language / theme / input_method — UI/locale prefs
    //   notifications_json — notification preferences blob
    //   privacy_mode_enabled — lock-screen privacy toggle
    'user_settings': [
      'id',
      'display_name',
      'phone_number',
      'avatar_path',
      'date_of_birth',
      'country',
      'currency',
      'language',
      'theme',
      'input_method',
      'notifications_json',
      'privacy_mode_enabled',
    ],
    'subscriptions': [
      'id',
      'account_id',
      'merchant_id',
      'name',
      'amount',
      'currency',
      'period',
      'frequency',
      'type',
      'next_due_date',
      'is_confirmed',
      'reminder_on',
      'custom_interval_days',
      'note',
      'created_at',
      'status',
      'total_installments',
      'paid_count',
      'manual_paid_amount',
      'total_purchase_amount',
      'lender_name',
      'interest_rate',
      'deleted_at',
    ],
    'bill_payments': [
      'id',
      'bill_id',
      'amount',
      'currency',
      'period_start',
      'period_end',
      'paid_at',
      'installment_index',
      'transaction_id',
      'note',
    ],
    'plans': [
      'id',
      'name',
      'budget_amount',
      'currency',
      'start_date',
      'end_date',
      'account_ids',
      'card_last4s',
      'status',
      'icon',
      'created_at',
      'deleted_at',
    ],
    'plan_transaction_links': [
      'plan_id',
      'transaction_id',
      'created_at',
    ],
    // Backed up in FULL — soft-deleted rows included (deleted_at preserved) —
    // because historical transactions and merchant_category_map may still
    // reference a soft-deleted category, and a card's archived state is
    // meaningful user data. Device-local sync columns are intentionally
    // dropped so a restored device re-syncs fresh.
    'cards': [
      'id',
      'account_id',
      'nickname',
      'last4',
      'network',
      'source',
      'color_theme',
      'accent_hex',
      'created_at',
      'updated_at',
      'deleted_at',
    ],
    'categories': [
      'id',
      'key',
      'name_ar',
      'icon',
      'color',
      'is_income',
      'sort_order',
      'deleted_at',
    ],
    // Only user-learned/user-adjusted mappings (see _customWhere) — server
    // catalog ('remote') and untouched pending suggestions are reproducible.
    'sender_bank_mappings': [
      'id',
      'sender_id',
      'normalized_sender_id',
      'bank_key',
      'suggested_bank_name',
      'suggested_country',
      'confidence',
      'reason',
      'status',
      'source',
      'first_seen_at',
      'last_seen_at',
      'confirmed_at',
      'rejected_at',
      'rejection_expires_at',
      'created_at',
      'updated_at',
    ],
  };

  // MALI-045n: parent tables that have FK children (subscriptions→bill_payments,
  // goals→goal_contributions, plans→plan_transaction_links) are backed up FULL
  // (soft-deleted rows included, deleted_at preserved) so a RETAINED (active)
  // child is never orphaned by a soft-deleted parent being filtered out — which
  // otherwise makes the snapshot FK-inconsistent and the restore fail. The
  // childless active-only tables below have no incoming FK, so filtering them to
  // active rows cannot orphan anything.
  static const _activeOnlyTables = {
    'accounts',
    'budgets',
    'goal_contributions',
    'bill_payments',
    'plan_transaction_links',
  };

  /// Per-table filter for rows that are user-authored vs server/seeded. Keeps
  /// the backup limited to data the user actually created or decided on.
  ///
  /// sender_bank_mappings: `remote` rows are reproducible server-owned data and
  /// are ALWAYS excluded — `confirm`/`reject` never rewrite `source`, and the
  /// sync-down path can deliver a server row already `confirmed`/`rejected`, so
  /// status alone can't prove local provenance. We therefore keep only
  /// non-remote rows that the user created (`user_manual`) or decided on
  /// (`confirmed`/`rejected`). A remote row the user confirmed locally is
  /// dropped by design — it re-syncs from the user's own server table, and no
  /// durable "user-touched" marker exists in the backup columns to keep it.
  static const _customWhere = <String, String>{
    'sender_bank_mappings': "source != 'remote' "
        "AND (source = 'user_manual' OR status IN ('confirmed', 'rejected'))",
  };

  /// Persistent tables deliberately NOT in a portable backup, with rationale:
  /// device-local sync state (outboxes, cursors, dedup), transient caches, and
  /// server-synced catalog (remote_*) — all rebuilt or re-synced, never
  /// user-authored financial data. Kept in sync with the schema by a coverage
  /// test so a new table can't silently escape both sets.
  static const intentionallyExcluded = <String>{
    'ledger_sync_outbox',
    'planning_sync_outbox',
    'sync_cursors',
    'parked_child_rows',
    // MALI-014 Batch-5 closure — the durable restore-operation journal is local
    // recovery state; it must never be backed up, restored, synced, or exported.
    'restore_operations',
    // MALI-024 — engagement events are device-local sync state; the server is
    // authoritative for the resulting XP/streak/achievement aggregate.
    'engagement_events',
    'dedup_hashes',
    'smart_inbox_items',
    'suspected_duplicates',
    'pending_merchant_feedback',
    'financial_cache_health',
    'financial_import_runs',
    'notification_log_events',
    'catalog_metadata',
    'parsing_rules',
    'xp_levels',
    'remote_announcements',
    'remote_banks',
    'remote_categories',
    'remote_countries',
    'remote_currencies',
    'remote_feature_flags',
    'remote_growth_campaigns',
    'remote_merchant_keywords',
    'remote_parsers',
  };

  /// Tables captured by the backup — exposed for the coverage-guard test.
  static Set<String> get backedUpTables => _tables.keys.toSet();

  /// The single source of truth for backup-safe columns, per table. The restore
  /// path uses this as its column WHITELIST (MALI-058n §6) so a snapshot key can
  /// never inject an arbitrary column name into restore SQL, and any excluded
  /// column (e.g. the deprecated db_encryption_key_ref) is dropped on the way in.
  static const Map<String, List<String>> restorableColumns = _tables;

  // MALI-030 — page size for the one usage-scaling backup table (transactions).
  static const int _snapshotPageSize = 2000;

  Future<Map<String, dynamic>> build({DateTime? createdAt}) async {
    final tables = <String, List<Map<String, Object?>>>{};
    // Read every table inside ONE transaction so the snapshot is a single
    // consistent point-in-time view even if writes land mid-build.
    await _db.transaction(() async {
      for (final entry in _tables.entries) {
        final columns = entry.value.join(', ');
        final where = _whereFor(entry.key);
        // MALI-030 — the transactions table scales with usage: read it in bounded
        // keyset pages so only [_snapshotPageSize] driver rows exist at once. Other
        // tables are small bounded catalogs/config. In BOTH cases the row maps are
        // taken directly (QueryRow.data is already a distinct map) instead of an
        // extra Map.from copy — the snapshot no longer holds two full copies.
        if (entry.key == 'transactions') {
          tables[entry.key] = await _pagedTableRows(entry.key, columns, where);
        } else {
          final rows = await _db
              .customSelect('SELECT $columns FROM ${entry.key}$where;')
              .get();
          tables[entry.key] = [for (final row in rows) row.data];
        }
      }
    });
    return {
      ..._metaMap(createdAt ?? DateTime.now().toUtc()),
      'tables': tables,
    };
  }

  /// The non-`tables` header, in the exact key order jsonEncode emits — shared by
  /// [build] (object path, for tests/compat) and [buildEncryptedPlaintext] (the
  /// streaming production path) so both produce byte-identical JSON.
  Map<String, dynamic> _metaMap(DateTime createdAt) => {
        'version': currentSchemaVersion,
        'schemaVersion': currentSchemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'privacy': {
          'rawMessageExcluded': true,
          'serverReadableFinancialData': false,
        },
      };

  /// MALI-030 (B2-B closure) — the PRODUCTION backup-encryption path: serialize the
  /// snapshot to canonical v3 JSON plaintext bytes INCREMENTALLY, one DB page at a
  /// time, WITHOUT ever building the full snapshot object graph or a whole JSON
  /// String. Only the growing plaintext byte buffer (the one buffer AES-GCM needs)
  /// and one page of driver rows exist at once. The [maxBytes] budget is checked AS
  /// bytes accumulate, so an oversized dataset throws typed
  /// [BackupEnvelopeErrorKind.payloadTooLarge] BEFORE a large String/graph is ever
  /// allocated — never an OOM. Output is byte-identical to
  /// `utf8.encode(jsonEncode(build(createdAt)))` (same schema/wire), proven by test.
  Future<Uint8List> buildEncryptedPlaintext({
    required int maxBytes,
    DateTime? createdAt,
  }) async {
    final out = BytesBuilder(copy: false);
    var size = 0;
    void add(String fragment) {
      final bytes = utf8.encode(fragment);
      size += bytes.length;
      if (size > maxBytes) {
        throw const BackupEnvelopeException(
          BackupEnvelopeErrorKind.payloadTooLarge,
        );
      }
      out.add(bytes);
    }

    final metaJson = jsonEncode(_metaMap(createdAt ?? DateTime.now().toUtc()));
    // Strip the header's closing '}' and open the tables object in its place.
    add(metaJson.substring(0, metaJson.length - 1));
    add(',"tables":{');
    await _db.transaction(() async {
      var firstTable = true;
      for (final entry in _tables.entries) {
        if (!firstTable) add(',');
        firstTable = false;
        add(jsonEncode(entry.key)); // properly-escaped "tableName"
        add(':[');
        final columns = entry.value.join(', ');
        final where = _whereFor(entry.key);
        var firstRow = true;
        void writeRow(Map<String, Object?> data) {
          if (!firstRow) add(',');
          firstRow = false;
          add(jsonEncode(data));
        }

        if (entry.key == 'transactions') {
          String? cursorId;
          while (true) {
            final keyset = cursorId == null
                ? ''
                : (where.isEmpty ? ' WHERE id > ?' : ' AND id > ?');
            final page = await _db.customSelect(
              'SELECT $columns FROM ${entry.key}$where$keyset ORDER BY id LIMIT ?;',
              variables: [
                if (cursorId != null) Variable.withString(cursorId),
                Variable.withInt(_snapshotPageSize),
              ],
            ).get();
            if (page.isEmpty) break;
            for (final row in page) {
              writeRow(row.data);
            }
            if (page.length < _snapshotPageSize) break;
            cursorId = page.last.data['id'] as String?;
          }
        } else {
          final rows = await _db
              .customSelect('SELECT $columns FROM ${entry.key}$where;')
              .get();
          for (final row in rows) {
            writeRow(row.data);
          }
        }
        add(']');
      }
    });
    add('}}'); // close the tables object and the outer object
    return out.toBytes();
  }

  /// MALI-030 — reads [table] in bounded keyset pages ordered by `id` (its primary
  /// key), so at most [_snapshotPageSize] driver rows exist at once. The [columns]
  /// allowlist already includes `id`. Row maps are taken directly (no extra copy).
  Future<List<Map<String, Object?>>> _pagedTableRows(
      String table, String columns, String where) async {
    final rows = <Map<String, Object?>>[];
    String? cursorId;
    while (true) {
      final keyset = cursorId == null
          ? ''
          : (where.isEmpty ? ' WHERE id > ?' : ' AND id > ?');
      final page = await _db.customSelect(
        'SELECT $columns FROM $table$where$keyset ORDER BY id LIMIT ?;',
        variables: [
          if (cursorId != null) Variable.withString(cursorId),
          Variable.withInt(_snapshotPageSize),
        ],
      ).get();
      if (page.isEmpty) break;
      for (final row in page) {
        rows.add(row.data);
      }
      if (page.length < _snapshotPageSize) break;
      cursorId = page.last.data['id'] as String?;
    }
    return rows;
  }

  static String _whereFor(String table) {
    if (_activeOnlyTables.contains(table)) return ' WHERE deleted_at IS NULL';
    final custom = _customWhere[table];
    if (custom != null) return ' WHERE $custom';
    return '';
  }
}
