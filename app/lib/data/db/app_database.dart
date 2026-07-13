import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/id_generator.dart';
import 'database_key_store.dart';
import 'database_seed.dart';
import 'sql_value_codec.dart';

const int _targetSchemaVersion = 21;

class AppDatabase extends GeneratedDatabase {
  AppDatabase._(
    DatabaseConnection connection, {
    required this.keyStore,
    required this.isEncrypted,
  }) : super.connect(connection);

  final DatabaseKeyStore keyStore;
  final bool isEncrypted;
  final _manualRevisionController = StreamController<int>.broadcast();
  var _manualRevision = 0;

  @override
  int get schemaVersion => _targetSchemaVersion;

  // Migrations are handled manually in initialize() → _runCompatibilityMigrations(),
  // which uses IF NOT EXISTS / ADD COLUMN IF NOT EXISTS and is fully idempotent.
  // This no-op strategy prevents Drift from throwing when it detects a version bump
  // on an existing database before initialize() has had a chance to run.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {},
        onUpgrade: (m, from, to) async {},
      );

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  static Future<AppDatabase> open({
    DatabaseKeyStore? keyStore,
    QueryExecutor? executor,
  }) async {
    final resolvedKeyStore = keyStore ?? SecureDatabaseKeyStore();
    if (executor != null) {
      final connection = executor is DatabaseConnection
          ? executor
          : DatabaseConnection(executor);
      final db = AppDatabase._(
        connection,
        keyStore: resolvedKeyStore,
        isEncrypted: false,
      );
      await db.initialize();
      return db;
    }

    final encryptionKey = await resolvedKeyStore.readOrCreateKey();
    final encryptedConnection = await _openEncryptedConnection(encryptionKey);
    final db = AppDatabase._(
      encryptedConnection,
      keyStore: resolvedKeyStore,
      isEncrypted: true,
    );
    await db.initialize();
    return db;
  }

  /// Deletes the on-disk encrypted database (and its WAL/SHM sidecars). Used by
  /// the recovery screen when the file can't be decrypted/opened — the data is
  /// unrecoverable without the key, so a clean recreate is the only way forward.
  static Future<void> deleteDatabaseFile() async {
    final directory = await getApplicationSupportDirectory();
    for (final suffix in const ['', '-wal', '-shm']) {
      final file =
          File(p.join(directory.path, 'money_companion.sqlite$suffix'));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> initialize() async {
    await customStatement('PRAGMA foreign_keys = ON;');
    await _createSchema();
    await _runCompatibilityMigrations();
    await _seedIfNeeded();
    await _dedupeCategoryRows();
    await _backfillSystemTransactionCategories();
    await _backfillTransactionDirections();
    await _repairBankCaptureTimestampDrift();
    await customStatement('PRAGMA user_version = $_targetSchemaVersion;');
  }

  @override
  Future<void> close() async {
    await _manualRevisionController.close();
    await executor.close();
  }

  Stream<int> get manualRevisionStream => _manualRevisionController.stream;

  @override
  Future<int> customInsert(
    String query, {
    List<Variable> variables = const [],
    Set<ResultSetImplementation<dynamic, dynamic>>? updates,
  }) async {
    final result = await super.customInsert(
      query,
      variables: variables,
      updates: updates,
    );
    _notifyManualRevision();
    return result;
  }

  @override
  Future<int> customUpdate(
    String query, {
    List<Variable> variables = const [],
    Set<ResultSetImplementation<dynamic, dynamic>>? updates,
    UpdateKind? updateKind,
  }) async {
    final result = await super.customUpdate(
      query,
      variables: variables,
      updates: updates,
      updateKind: updateKind,
    );
    _notifyManualRevision();
    return result;
  }

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (_looksLikeDataWrite(statement)) {
      _notifyManualRevision();
    }
  }

  void _notifyManualRevision() {
    if (_manualRevisionController.isClosed) return;
    _manualRevisionController.add(++_manualRevision);
  }

  bool _looksLikeDataWrite(String sql) {
    final trimmed = sql.trimLeft().toUpperCase();
    return trimmed.startsWith('INSERT ') ||
        trimmed.startsWith('UPDATE ') ||
        trimmed.startsWith('DELETE ') ||
        trimmed.startsWith('REPLACE ');
  }

  Future<int> count(String table) async {
    final rows =
        await customSelect('SELECT COUNT(*) AS total FROM $table;').get();
    return rows.first.read<int>('total');
  }

  static Future<DatabaseConnection> _openEncryptedConnection(String key) async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'money_companion.sqlite'));
    return NativeDatabase.createBackgroundConnection(
      file,
      setup: (database) {
        database.execute("PRAGMA cipher = 'sqlcipher';");
        final cipher = database.select('PRAGMA cipher;');
        if (cipher.isEmpty) {
          throw StateError(
            'SQLite encryption extension is not available. The database would not be encrypted.',
          );
        }
        database.execute("PRAGMA key = '${escapeSqlString(key)}';");
        database.select('SELECT count(*) FROM sqlite_master;');
        database.execute('PRAGMA foreign_keys = ON;');
      },
    );
  }

  Future<void> _createSchema() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS categories(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        icon TEXT NOT NULL,
        color TEXT NOT NULL,
        is_income INTEGER NOT NULL,
        sort_order INTEGER NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS merchants(
        id TEXT PRIMARY KEY,
        raw_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE,
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS merchant_category_map(
        id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL UNIQUE,
        category_id TEXT NOT NULL,
        is_user_confirmed INTEGER NOT NULL,
        confidence REAL NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        merchant_id TEXT NULL,
        raw_merchant TEXT NULL,
        category_id TEXT NULL,
        type TEXT NOT NULL,
        source TEXT NOT NULL,
        card_last4 TEXT NULL,
        balance_after REAL NULL,
        note TEXT NULL,
        occurred_at TEXT NOT NULL,
        raw_message TEXT NOT NULL,
        parse_confidence REAL NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        foreign_amount REAL NULL,
        foreign_currency TEXT NULL,
        direction TEXT NULL CHECK(direction IN ('credit', 'debit', 'unknown')),
        transaction_time_from_sms TEXT NULL,
        sms_received_at TEXT NULL,
        comparison_timestamp TEXT NULL,
        comparison_timestamp_source TEXT NOT NULL DEFAULT 'received_at'
          CHECK(comparison_timestamp_source IN ('sms_body', 'received_at')),
        duplicate_status TEXT NOT NULL DEFAULT 'normal'
          CHECK(duplicate_status IN ('normal', 'suspicious_duplicate')),
        possible_duplicate_of_transaction_id TEXT NULL,
        duplicate_reason TEXT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE SET NULL,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL
      );
    ''');

    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_occurred_at ON transactions(occurred_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_merchant_amount ON transactions(merchant_id, amount);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_duplicate_exact '
      'ON transactions(amount, currency, comparison_timestamp);',
    );

    await customStatement('''
      CREATE TABLE IF NOT EXISTS budgets(
        id TEXT PRIMARY KEY,
        category_id TEXT NOT NULL,
        amount REAL NOT NULL,
        period TEXT NOT NULL,
        start_date TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        alert_80_sent INTEGER NOT NULL,
        alert_100_sent INTEGER NOT NULL,
        show_on_header INTEGER NOT NULL DEFAULT 0,
        account_id TEXT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        account_id TEXT NULL,
        target_amount REAL NOT NULL,
        saved_amount REAL NOT NULL,
        deadline TEXT NULL,
        vault_skin TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        auto_save_amount REAL NULL,
        auto_save_period TEXT NULL,
        auto_save_last_run TEXT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS goal_contributions(
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL,
        amount REAL NOT NULL,
        created_at TEXT NOT NULL,
        note TEXT NULL,
        FOREIGN KEY (goal_id) REFERENCES goals(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS achievements(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        unlocked_at TEXT NULL,
        progress REAL NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS streaks(
        id TEXT PRIMARY KEY,
        current_streak INTEGER NOT NULL,
        longest_streak INTEGER NOT NULL,
        last_active_date TEXT NOT NULL,
        freezes_available INTEGER NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS xp_levels(
        id TEXT PRIMARY KEY,
        total_xp INTEGER NOT NULL,
        level INTEGER NOT NULL,
        level_key TEXT NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS subscriptions(
        id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL,
        amount REAL NOT NULL,
        period TEXT NOT NULL,
        next_due_date TEXT NULL,
        is_confirmed INTEGER NOT NULL,
        reminder_on INTEGER NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL DEFAULT 'subscription',
        currency TEXT NOT NULL DEFAULT 'SAR',
        frequency TEXT NOT NULL DEFAULT 'monthly',
        custom_interval_days INTEGER NULL,
        note TEXT NULL,
        created_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z',
        status TEXT NOT NULL DEFAULT 'active',
        account_id TEXT NULL,
        total_installments INTEGER NULL,
        paid_count INTEGER NULL,
        manual_paid_amount REAL NULL,
        total_purchase_amount REAL NULL,
        lender_name TEXT NULL,
        interest_rate REAL NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE
      );
    ''');

    await _createBillPaymentsTable();

    await customStatement('''
      CREATE TABLE IF NOT EXISTS parsing_rules(
        id TEXT PRIMARY KEY,
        bank_key TEXT NOT NULL,
        locale TEXT NOT NULL,
        pattern TEXT NOT NULL,
        field TEXT NOT NULL,
        priority INTEGER NOT NULL,
        version INTEGER NOT NULL,
        is_active INTEGER NOT NULL
      );
    ''');

    await _createCatalogMetadataTable();
    await _createRemoteBanksTable();
    await _createRemoteParsersTable();
    await _createRemoteCurrenciesTable();
    await _createRemoteCountriesTable();
    await _createRemoteCategoriesTable();
    await _createRemoteFeatureFlagsTable();
    await _createRemoteAnnouncementsTable();
    await _createRemoteGrowthCampaignsTable();

    await customStatement('''
      CREATE TABLE IF NOT EXISTS user_settings(
        id TEXT PRIMARY KEY,
        display_name TEXT NULL,
        phone_number TEXT NULL,
        avatar_path TEXT NULL,
        date_of_birth TEXT NULL,
        country TEXT NOT NULL,
        currency TEXT NOT NULL,
        language TEXT NOT NULL,
        theme TEXT NOT NULL,
        input_method TEXT NOT NULL,
        notifications_json TEXT NOT NULL,
        db_encryption_key_ref TEXT NOT NULL,
        privacy_mode_enabled INTEGER NOT NULL DEFAULT 0,
        cloud_processing_enabled INTEGER NOT NULL DEFAULT 0
      );
    ''');

    // الحسابات/المحافظ — كل حساب بعملته الخاصة (multi-currency).
    await customStatement('''
      CREATE TABLE IF NOT EXISTS accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        currency TEXT NOT NULL,
        type TEXT NOT NULL,
        initial_balance REAL NULL,
        current_balance REAL NULL,
        is_default INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');

    // Phase 2: تتبّع صحة الكاش المحلي (Drift) أثناء فترة الطرح التدريجي
    // للقراءة/الكتابة المباشرة على Supabase. يُستخدم فقط لمعرفة متى فشلت
    // مرآة الكتابة بعد نجاح Supabase، حتى لا يُعتبر التراجع (rollback) آمنًا
    // بشكل أعمى قبل إصلاح الكاش.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS financial_cache_health(
        entity_type TEXT PRIMARY KEY,
        dirty INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        marked_at TEXT NULL,
        repaired_at TEXT NULL
      );
    ''');

    await _createDedupHashesTable();
    await _createRemoteMerchantKeywordsTable();
    await _createPendingMerchantFeedbackTable();
    await _createSenderBankMappingsTable();
    await _createPlansTable();
    await _createSuspectedDuplicatesTable();
  }

  Future<void> _createSuspectedDuplicatesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS suspected_duplicates(
        id TEXT PRIMARY KEY,
        raw_message TEXT NOT NULL,
        sender_id TEXT NULL,
        existing_transaction_id TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        raw_merchant TEXT NULL,
        occurred_at TEXT NOT NULL,
        card_last4 TEXT NULL,
        comparison_timestamp TEXT NULL,
        comparison_timestamp_source TEXT NULL,
        duplicate_reason TEXT NULL,
        created_at TEXT NOT NULL
      );
    ''');
  }

  /// خطط/مظاريف مؤقتة (سفر، عُرس، رمضان...) — ميزانية لفترة محددة بتتبّع تلقائياً
  /// أي صرف في الفترة من الحسابات/الكروت المختارة. عضوية العمليات محسوبة ديناميكياً
  /// (مفيش عمود على transactions)، فالجدول بيتعمل بـ IF NOT EXISTS لكل النسخ.
  Future<void> _createPlansTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS plans(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        budget_amount REAL NOT NULL,
        currency TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        account_ids TEXT NOT NULL DEFAULT '',
        card_last4s TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active',
        icon TEXT NULL,
        created_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS plan_transaction_links(
        plan_id TEXT NOT NULL,
        transaction_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (plan_id, transaction_id),
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE,
        FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_plan_transaction_links_transaction '
      'ON plan_transaction_links(transaction_id);',
    );
  }

  Future<void> _runCompatibilityMigrations() async {
    final version = await _currentUserVersion();
    // v2 consolidates the manual columns added during MVP hardening. The
    // checks stay idempotent because older builds could write user_version
    // before all compatibility columns existed.
    if (version > _targetSchemaVersion) {
      throw StateError('Unsupported database schema version: $version');
    }
    await _ensureColumn('transactions', 'note', 'TEXT NULL');
    await _ensureColumn('remote_merchant_keywords', 'logo_url', 'TEXT');
    await _ensureColumn('subscriptions', 'name', "TEXT NOT NULL DEFAULT ''");
    await _ensureColumn(
      'subscriptions',
      'type',
      "TEXT NOT NULL DEFAULT 'subscription'",
    );
    await _ensureColumn(
      'subscriptions',
      'currency',
      "TEXT NOT NULL DEFAULT 'SAR'",
    );
    await _ensureColumn(
      'subscriptions',
      'frequency',
      "TEXT NOT NULL DEFAULT 'monthly'",
    );
    await _ensureColumn(
      'subscriptions',
      'custom_interval_days',
      'INTEGER NULL',
    );
    await _ensureColumn('subscriptions', 'note', 'TEXT NULL');
    await _ensureColumn(
      'subscriptions',
      'created_at',
      "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z'",
    );
    await _ensureColumn(
      'user_settings',
      'privacy_mode_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'user_settings',
      'ai_consent_granted',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      'user_settings',
      'cloud_processing_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn('user_settings', 'display_name', 'TEXT NULL');
    await _ensureColumn('user_settings', 'phone_number', 'TEXT NULL');
    await _ensureColumn('user_settings', 'avatar_path', 'TEXT NULL');
    await _ensureColumn('user_settings', 'date_of_birth', 'TEXT NULL');
    // v2: ربط المعاملات/الاشتراكات بالحساب (multi-currency accounts).
    await _ensureColumn('transactions', 'account_id', 'TEXT NULL');
    await _ensureColumn('subscriptions', 'account_id', 'TEXT NULL');
    await _ensureColumn(
        'budgets', 'show_on_header', 'INTEGER NOT NULL DEFAULT 0');
    await _ensureColumn('budgets', 'account_id', 'TEXT NULL');
    await _ensureColumn('goals', 'account_id', 'TEXT NULL');
    // recurring auto-save per goal (fixed amount every week/month).
    await _ensureColumn('goals', 'auto_save_amount', 'REAL NULL');
    await _ensureColumn('goals', 'auto_save_period', 'TEXT NULL');
    await _ensureColumn('goals', 'auto_save_last_run', 'TEXT NULL');
    // subscription/installment extra fields
    await _ensureColumn(
        'subscriptions', 'status', "TEXT NOT NULL DEFAULT 'active'");
    await _ensureColumn('subscriptions', 'total_installments', 'INTEGER NULL');
    await _ensureColumn('subscriptions', 'paid_count', 'INTEGER NULL');
    await _ensureColumn('subscriptions', 'manual_paid_amount', 'REAL NULL');
    await _ensureColumn('subscriptions', 'total_purchase_amount', 'REAL NULL');
    await _ensureColumn('subscriptions', 'lender_name', 'TEXT NULL');
    await _ensureColumn('subscriptions', 'interest_rate', 'REAL NULL');
    await _createBillPaymentsTable();
    await _createSuspectedDuplicatesTable();

    if (version < 3) {
      await _createCatalogMetadataTable();
      await _createRemoteBanksTable();
      await _createRemoteParsersTable();
      await _createRemoteCurrenciesTable();
      await _createRemoteCountriesTable();
      await _createRemoteCategoriesTable();
    }
    if (version < 4) {
      await _createRemoteFeatureFlagsTable();
      await _createRemoteAnnouncementsTable();
    }
    if (version < 5) {
      await _createDedupHashesTable();
    }
    if (version < 6) {
      await _createRemoteMerchantKeywordsTable();
      await _createPendingMerchantFeedbackTable();
    }
    if (version < 7) {
      await _createSenderBankMappingsTable();
    }
    if (version < 13) {
      await _createRemoteGrowthCampaignsTable();
    }
    if (version < 8) {
      await _ensureColumn('sender_bank_mappings', 'reason', 'TEXT NULL');
    }
    if (version < 9) {
      await _ensureColumn('transactions', 'foreign_amount', 'REAL NULL');
      await _ensureColumn('transactions', 'foreign_currency', 'TEXT NULL');
    }
    await _ensureColumn(
      'transactions',
      'direction',
      "TEXT NULL CHECK(direction IN ('credit', 'debit', 'unknown'))",
    );
    await _ensureColumn(
        'transactions', 'transaction_time_from_sms', 'TEXT NULL');
    await _ensureColumn('transactions', 'sms_received_at', 'TEXT NULL');
    await _ensureColumn('transactions', 'comparison_timestamp', 'TEXT NULL');
    await _ensureColumn(
      'transactions',
      'comparison_timestamp_source',
      "TEXT NOT NULL DEFAULT 'received_at' "
          "CHECK(comparison_timestamp_source IN ('sms_body', 'received_at'))",
    );
    await _ensureColumn(
      'transactions',
      'duplicate_status',
      "TEXT NOT NULL DEFAULT 'normal' "
          "CHECK(duplicate_status IN ('normal', 'suspicious_duplicate'))",
    );
    await _ensureColumn(
      'transactions',
      'possible_duplicate_of_transaction_id',
      'TEXT NULL',
    );
    await _ensureColumn('transactions', 'duplicate_reason', 'TEXT NULL');
    await _ensureColumn('suspected_duplicates', 'card_last4', 'TEXT NULL');
    await _ensureColumn(
      'suspected_duplicates',
      'comparison_timestamp',
      'TEXT NULL',
    );
    await _ensureColumn(
      'suspected_duplicates',
      'comparison_timestamp_source',
      'TEXT NULL',
    );
    await _ensureColumn(
        'suspected_duplicates', 'duplicate_reason', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_duplicate_exact '
      'ON transactions(amount, currency, comparison_timestamp);',
    );
    if (version < 10) {
      await _backfillGoalsToDefaultAccount();
    }
    // v15: Phase C — server sync metadata for Supabase ledger pull.
    await _ensureColumn('transactions', 'server_id', 'TEXT NULL');
    await _ensureColumn('transactions', 'synced_at', 'TEXT NULL');
    await _ensureColumn('transactions', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn(
      'transactions',
      'sync_status',
      "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_server_id ON transactions(server_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_sync_status ON transactions(sync_status);',
    );
    // v16: Phase D — local outbox for push sync.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS ledger_sync_outbox (
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN ('create','update','delete')),
        payload_json TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        next_retry_at TEXT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_transaction_id '
      'ON ledger_sync_outbox(transaction_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_next_retry '
      'ON ledger_sync_outbox(next_retry_at);',
    );
    // v17: Phase F — Smart Inbox pull-sync cache.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS smart_inbox_items (
        id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL UNIQUE,
        transaction_id TEXT NULL,
        payload_id TEXT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NULL,
        status TEXT NOT NULL DEFAULT 'open',
        confidence REAL NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        server_created_at TEXT NOT NULL,
        server_updated_at TEXT NULL,
        synced_at TEXT NOT NULL,
        dismissed_locally INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_smart_inbox_type '
      'ON smart_inbox_items(type);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_smart_inbox_status '
      'ON smart_inbox_items(status);',
    );
    // v18-v19: Phase G — planning sync foundation.
    await _ensureAccountsSyncSchema();
    await _ensurePlanningEntitySyncSchema();
    await _ensurePlanningChildSyncSchema();
    await _createPlanningSyncOutboxTable();
  }

  Future<void> _ensureAccountsSyncSchema() async {
    await _ensureColumn('accounts', 'server_id', 'TEXT NULL');
    await _ensureColumn('accounts', 'synced_at', 'TEXT NULL');
    await _ensureColumn('accounts', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn(
      'accounts',
      'sync_status',
      "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
    );
    await _ensureColumn('accounts', 'deleted_at', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_server_id ON accounts(server_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_sync_status ON accounts(sync_status);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_deleted_at ON accounts(deleted_at);',
    );
  }

  Future<void> _createPlanningSyncOutboxTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS planning_sync_outbox (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN ('create','update','delete')),
        payload_json TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        next_retry_at TEXT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_planning_outbox_entity '
      'ON planning_sync_outbox(entity_type, entity_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_planning_outbox_next_retry '
      'ON planning_sync_outbox(next_retry_at);',
    );
  }

  Future<void> _ensurePlanningEntitySyncSchema() async {
    for (final table in const [
      'budgets',
      'subscriptions',
      'goals',
      'plans',
    ]) {
      await _ensureColumn(table, 'server_id', 'TEXT NULL');
      await _ensureColumn(table, 'synced_at', 'TEXT NULL');
      await _ensureColumn(table, 'server_updated_at', 'TEXT NULL');
      await _ensureColumn(
        table,
        'sync_status',
        "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
      );
      await _ensureColumn(table, 'deleted_at', 'TEXT NULL');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_server_id ON $table(server_id);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_sync_status ON $table(sync_status);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_deleted_at ON $table(deleted_at);',
      );
    }
  }

  Future<void> _ensurePlanningChildSyncSchema() async {
    for (final table in const [
      'goal_contributions',
      'bill_payments',
      'plan_transaction_links',
    ]) {
      await _ensureColumn(table, 'server_id', 'TEXT NULL');
      await _ensureColumn(table, 'synced_at', 'TEXT NULL');
      await _ensureColumn(table, 'server_updated_at', 'TEXT NULL');
      await _ensureColumn(
        table,
        'sync_status',
        "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
      );
      await _ensureColumn(table, 'deleted_at', 'TEXT NULL');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_server_id ON $table(server_id);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_deleted_at ON $table(deleted_at);',
      );
    }
  }

  /// Removes dedup hashes older than [daysOld] days to prevent unbounded growth.
  ///
  /// صفوف `capture_payload:` مستثناة دائمًا: هي سجل "تم الاستيراد" الدائم
  /// لالتقاطات iOS/الدفتر وتُخزَّن بـ occurred_at ثابت عند epoch-0 (توقيع
  /// مساحة الأسماء وليس وقتًا حقيقيًا)، فحذفها بعمر occurred_at يمحو السجل
  /// كله ويسمح بإعادة استيراد Capture لم يُؤكَّد (ack) بعد — أي تكرار عملية.
  Future<void> pruneOldDedupHashes({int daysOld = 30}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: daysOld));
    await customStatement(
      "DELETE FROM dedup_hashes "
      "WHERE occurred_at < '${cutoff.toIso8601String()}' "
      "AND hash NOT LIKE 'capture_payload:%';",
    );
  }

  Future<void> _createSenderBankMappingsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sender_bank_mappings(
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        normalized_sender_id TEXT NOT NULL UNIQUE,
        bank_key TEXT NULL,
        suggested_bank_name TEXT NOT NULL,
        suggested_country TEXT NOT NULL,
        confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
        reason TEXT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending', 'confirmed', 'rejected')),
        source TEXT NOT NULL CHECK(source IN ('gemini', 'user_manual', 'remote')),
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        confirmed_at TEXT NULL,
        rejected_at TEXT NULL,
        rejection_expires_at TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced_at TEXT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK(sync_status IN ('pending', 'synced', 'failed')),
        CHECK(status != 'confirmed' OR confirmed_at IS NOT NULL),
        CHECK(status != 'rejected' OR rejected_at IS NOT NULL)
      );
    ''');
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sender_bank_mappings_normalized_sender '
      'ON sender_bank_mappings(normalized_sender_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_status '
      'ON sender_bank_mappings(status);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_sync_status '
      'ON sender_bank_mappings(sync_status);',
    );
  }

  Future<void> _createDedupHashesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS dedup_hashes(
        hash TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        saved_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_dedup_hashes_occurred_at ON dedup_hashes(occurred_at);',
    );
  }

  Future<void> _createBillPaymentsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS bill_payments(
        id TEXT PRIMARY KEY,
        bill_id TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        period_start TEXT NOT NULL,
        period_end TEXT NOT NULL,
        paid_at TEXT NOT NULL,
        installment_index INTEGER NULL,
        transaction_id TEXT NULL,
        note TEXT NULL,
        FOREIGN KEY (bill_id) REFERENCES subscriptions(id) ON DELETE CASCADE
      );
    ''');
    await _ensureColumn('bill_payments', 'transaction_id', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_bill_payments_bill_id ON bill_payments(bill_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_bill_payments_transaction_id ON bill_payments(transaction_id);',
    );
  }

  Future<void> _createCatalogMetadataTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS catalog_metadata(
        category TEXT PRIMARY KEY,
        server_version INTEGER NOT NULL,
        local_version INTEGER NOT NULL,
        last_synced_at TEXT NULL,
        etag TEXT NULL
      );
    ''');
  }

  Future<void> _createRemoteBanksTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_banks(
        id TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        short_code TEXT NOT NULL UNIQUE,
        logo_url TEXT NULL,
        country_code TEXT NOT NULL,
        sms_senders TEXT NOT NULL,
        supported_currencies TEXT NOT NULL,
        color_hex TEXT NULL,
        is_active INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteParsersTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_parsers(
        id TEXT PRIMARY KEY,
        bank_id TEXT NOT NULL,
        sender_pattern TEXT NOT NULL,
        message_pattern TEXT NOT NULL,
        transaction_type TEXT NOT NULL,
        language TEXT NOT NULL,
        priority INTEGER NOT NULL,
        extracted_fields TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (bank_id) REFERENCES remote_banks(id) ON DELETE CASCADE
      );
    ''');
  }

  Future<void> _createRemoteCurrenciesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_currencies(
        code TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        symbol TEXT NOT NULL,
        decimal_places INTEGER NOT NULL,
        country_codes TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteCountriesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_countries(
        code TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        flag_emoji TEXT NOT NULL,
        phone_prefix TEXT NOT NULL,
        is_supported INTEGER NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteCategoriesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_categories(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        icon TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        parent_key TEXT NULL,
        type TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        is_system INTEGER NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteFeatureFlagsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_feature_flags(
        key TEXT PRIMARY KEY,
        value_type TEXT NOT NULL,
        value TEXT NOT NULL,
        rollout_percent INTEGER NOT NULL DEFAULT 100,
        target_countries TEXT NOT NULL DEFAULT '[]',
        is_active INTEGER NOT NULL DEFAULT 1,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteAnnouncementsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_announcements(
        id TEXT PRIMARY KEY,
        title_ar TEXT NOT NULL,
        title_en TEXT NOT NULL,
        body_ar TEXT NULL,
        body_en TEXT NULL,
        severity TEXT NOT NULL,
        min_app_version TEXT NULL,
        max_app_version TEXT NULL,
        action_label_ar TEXT NULL,
        action_label_en TEXT NULL,
        action_url TEXT NULL,
        valid_from TEXT NOT NULL,
        valid_until TEXT NULL,
        is_dismissible INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL DEFAULT 0,
        is_dismissed INTEGER NOT NULL DEFAULT 0,
        dismissed_at TEXT NULL,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteGrowthCampaignsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_growth_campaigns(
        id TEXT PRIMARY KEY,
        title_ar TEXT NOT NULL,
        title_en TEXT NOT NULL,
        body_ar TEXT NULL,
        body_en TEXT NULL,
        type TEXT NOT NULL,
        target_segment TEXT NOT NULL,
        action_label_ar TEXT NULL,
        action_label_en TEXT NULL,
        action_route TEXT NULL,
        action_url TEXT NULL,
        valid_from TEXT NOT NULL,
        valid_until TEXT NULL,
        max_impressions INTEGER NULL,
        cooldown_hours INTEGER NOT NULL DEFAULT 24,
        is_dismissible INTEGER NOT NULL DEFAULT 1,
        once_per_user INTEGER NOT NULL DEFAULT 0,
        priority INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteMerchantKeywordsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_merchant_keywords(
        id TEXT PRIMARY KEY,
        keyword TEXT NOT NULL,
        category_key TEXT NOT NULL,
        language TEXT NOT NULL DEFAULT 'any',
        country_code TEXT NOT NULL DEFAULT 'ALL',
        priority INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        logo_url TEXT
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_rmk_country_active '
      'ON remote_merchant_keywords(country_code, is_active);',
    );
  }

  Future<void> _createPendingMerchantFeedbackTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS pending_merchant_feedback(
        normalized_keyword TEXT PRIMARY KEY,
        seen_count INTEGER NOT NULL DEFAULT 1,
        last_seen_at TEXT NOT NULL
      );
    ''');
  }

  Future<int> _currentUserVersion() async {
    final row = await customSelect('PRAGMA user_version;').getSingle();
    return row.read<int>('user_version');
  }

  Future<void> _ensureColumn(
    String table,
    String column,
    String definition,
  ) async {
    final rows = await customSelect('PRAGMA table_info($table);').get();
    final exists = rows.any((row) => row.read<String>('name') == column);
    if (!exists) {
      await customStatement(
          'ALTER TABLE $table ADD COLUMN $column $definition;');
    }
  }

  Future<void> _seedIfNeeded() async {
    if (await count('categories') == 0) {
      for (final category in DatabaseSeed.categories) {
        await customInsert(
          '''
            INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(category.id),
            Variable.withString(category.key),
            Variable.withString(category.nameAr),
            Variable.withString(category.icon),
            Variable.withString(category.color),
            Variable.withInt(boolToSql(category.isIncome)),
            Variable.withInt(category.sort),
          ],
        );
      }
    }
    await _ensureInternalCategories();

    if (await count('merchants') == 0 &&
        await count('merchant_category_map') == 0 &&
        await count('remote_merchant_keywords') == 0) {
      for (final mapping in DatabaseSeed.merchantMappings) {
        final merchantId = IdGenerator.next();
        final now = DateTime.now().toUtc();
        final categoryId = await _categoryIdByKey(mapping.categoryKey);
        if (categoryId == null) {
          continue;
        }

        await customInsert(
          '''
            INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(merchantId),
            Variable.withString(mapping.rawName),
            Variable.withString(_normalizeMerchant(mapping.rawName)),
            Variable.withString(dateTimeToSql(now)),
            Variable.withString(dateTimeToSql(now)),
          ],
        );

        await customInsert(
          '''
            INSERT INTO merchant_category_map(
              id, merchant_id, category_id, is_user_confirmed, confidence, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(IdGenerator.next()),
            Variable.withString(merchantId),
            Variable.withString(categoryId),
            Variable.withInt(0),
            Variable.withReal(mapping.confidence),
            Variable.withString(dateTimeToSql(now)),
          ],
        );
      }
    }

    if (await count('achievements') == 0) {
      for (final achievement in DatabaseSeed.achievements) {
        await customInsert(
          '''
            INSERT INTO achievements(id, key, name_ar, unlocked_at, progress)
            VALUES (?, ?, ?, NULL, ?);
          ''',
          variables: [
            Variable.withString(achievement.id),
            Variable.withString(achievement.key),
            Variable.withString(achievement.nameAr),
            Variable.withReal(achievement.progress),
          ],
        );
      }
    }

    if (await count('streaks') == 0) {
      await customInsert(
        '''
          INSERT INTO streaks(id, current_streak, longest_streak, last_active_date, freezes_available)
          VALUES (?, 0, 0, ?, 1);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        ],
      );
    }

    if (await count('xp_levels') == 0) {
      await customInsert(
        '''
          INSERT INTO xp_levels(id, total_xp, level, level_key)
          VALUES (?, 0, 1, 'beginner');
        ''',
        variables: [Variable.withString(IdGenerator.next())],
      );
    }

    if (await count('user_settings') == 0) {
      final keyRef = await keyStore.readStoredKey() ?? '';
      await customInsert(
        '''
          INSERT INTO user_settings(
            id, country, currency, language, theme, input_method, notifications_json, db_encryption_key_ref, privacy_mode_enabled
          )
          VALUES (?, 'SA', 'SAR', 'ar', 'system', 'auto', '{"captureReview":true,"captureLight":true,"budgetWarning":true,"budgetOver":true,"achievements":true,"streakReminder":true,"weeklyReport":true,"subscriptionReminder":true,"goalMilestone":true,"quietHoursEnabled":false,"quietHoursStartHour":23,"quietHoursEndHour":8,"notifiedGoalMilestones":{}}', ?, 0);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(keyRef),
        ],
      );
    }

    await _ensureDefaultAccount();
  }

  /// يُستدعى بعد استعادة نسخة احتياطية لضمان وجود حساب افتراضي وربط
  /// أي سجلات يتيمة (account_id = NULL) به.
  Future<void> runPostRestoreSetup() => _ensureDefaultAccount();

  /// ينشئ حساباً افتراضياً واحداً من عملة المستخدم الحالية، ويربط كل العمليات
  /// والاشتراكات القائمة (بدون حساب) به. آمن وبدون فقدان بيانات.
  Future<void> _ensureDefaultAccount() async {
    if (await count('accounts') > 0) {
      // اضمن وجود حساب افتراضي واحد على الأقل.
      final defaults = await customSelect(
        'SELECT id FROM accounts WHERE is_default = 1 LIMIT 1;',
      ).get();
      if (defaults.isEmpty) {
        await customStatement(
          'UPDATE accounts SET is_default = 1 WHERE id = '
          '(SELECT id FROM accounts ORDER BY sort_order ASC LIMIT 1);',
        );
      }
    } else {
      final settingsRow = await customSelect(
        'SELECT currency FROM user_settings LIMIT 1;',
      ).getSingleOrNull();
      final currency = settingsRow?.read<String>('currency') ?? 'SAR';
      final accountId = IdGenerator.next();
      final now = dateTimeToSql(DateTime.now().toUtc());
      await customInsert(
        '''
          INSERT INTO accounts(
            id, name, currency, type, initial_balance, current_balance,
            is_default, sort_order, created_at, updated_at
          )
          VALUES (?, ?, ?, 'bank', NULL, NULL, 1, 0, ?, ?);
        ''',
        variables: [
          Variable.withString(accountId),
          Variable.withString('الحساب الرئيسي'),
          Variable.withString(currency),
          Variable.withString(now),
          Variable.withString(now),
        ],
      );
      // backfill: اربط كل العمليات/الاشتراكات القائمة بالحساب الافتراضي.
      await customStatement(
        'UPDATE transactions SET account_id = ${sqlString(accountId)} '
        'WHERE account_id IS NULL;',
      );
      await customStatement(
        'UPDATE subscriptions SET account_id = ${sqlString(accountId)} '
        'WHERE account_id IS NULL;',
      );
    }
    await _backfillGoalsToDefaultAccount();
  }

  Future<void> _backfillGoalsToDefaultAccount() async {
    final row = await customSelect(
      'SELECT id FROM accounts WHERE is_default = 1 LIMIT 1;',
    ).getSingleOrNull();
    final accountId = row?.read<String>('id');
    if (accountId == null) return;
    await customStatement(
      'UPDATE goals SET account_id = ${sqlString(accountId)} '
      'WHERE account_id IS NULL;',
    );
  }

  // Idempotently ensures every seed category (internal + new ones added in
  // later app versions) exists. INSERT OR IGNORE keys off the UNIQUE `key`, so
  // existing rows are untouched and only genuinely new categories are inserted.
  Future<void> _ensureInternalCategories() async {
    for (final category in DatabaseSeed.categories) {
      await customInsert(
        '''
          INSERT OR IGNORE INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
          VALUES (?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(category.id),
          Variable.withString(category.key),
          Variable.withString(category.nameAr),
          Variable.withString(category.icon),
          Variable.withString(category.color),
          Variable.withInt(boolToSql(category.isIncome)),
          Variable.withInt(category.sort),
        ],
      );
    }
  }

  // Repairs DBs that ended up with duplicate category rows (same `key`, which
  // crashed category dropdowns). Repoints every FK reference to the canonical
  // (lowest-rowid) row per key, then deletes the duplicates.
  Future<void> _dedupeCategoryRows() async {
    final dup = await customSelect(
      'SELECT COUNT(*) - COUNT(DISTINCT key) AS d FROM categories;',
    ).getSingle();
    if (dup.read<int>('d') == 0) return;

    for (final table in const [
      'transactions',
      'budgets',
      'merchant_category_map'
    ]) {
      await customStatement('''
        UPDATE $table SET category_id = (
          SELECT c.id FROM categories c
          WHERE c.key = (SELECT k.key FROM categories k WHERE k.id = $table.category_id)
          ORDER BY c.rowid LIMIT 1
        )
        WHERE category_id IS NOT NULL
          AND category_id NOT IN (
            SELECT id FROM categories
            WHERE rowid IN (SELECT MIN(rowid) FROM categories GROUP BY key)
          );
      ''');
    }
    await customStatement(
      'DELETE FROM categories WHERE rowid NOT IN '
      '(SELECT MIN(rowid) FROM categories GROUP BY key);',
    );
  }

  Future<void> _backfillSystemTransactionCategories() async {
    for (final entry in const {
      'transfer': 'transfers',
      'withdrawal': 'cash',
      'income': 'income',
    }.entries) {
      await customUpdate(
        '''
          UPDATE transactions
          SET category_id = (
            SELECT id FROM categories WHERE key = ? LIMIT 1
          )
          WHERE type = ?
            AND (
              category_id IS NULL OR
              category_id != (SELECT id FROM categories WHERE key = ? LIMIT 1)
            );
        ''',
        variables: [
          Variable.withString(entry.value),
          Variable.withString(entry.key),
          Variable.withString(entry.value),
        ],
      );
    }
    await customUpdate(
      '''
        UPDATE transactions
        SET merchant_id = NULL, raw_merchant = NULL
        WHERE type IN ('transfer', 'income');
      ''',
    );
  }

  Future<void> _backfillTransactionDirections() async {
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'credit'
        WHERE direction IS NULL
          AND (
            raw_message LIKE '%credited%' OR
            raw_message LIKE '%received%' OR
            raw_message LIKE '%incoming%' OR
            raw_message LIKE '%إيداع%' OR
            raw_message LIKE '%ايداع%' OR
            raw_message LIKE '%إضافة%' OR
            raw_message LIKE '%اضافة%' OR
            raw_message LIKE '%تم إضافة%' OR
            raw_message LIKE '%تم اضافة%' OR
            raw_message LIKE '%حوالة واردة%' OR
            raw_message LIKE '%مبلغ وارد%'
          );
      ''',
    );
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'debit'
        WHERE direction IS NULL
          AND (
            type IN ('payment', 'withdrawal') OR
            raw_message LIKE '%debited%' OR
            raw_message LIKE '%deducted%' OR
            raw_message LIKE '%withdrawn%' OR
            raw_message LIKE '%purchase%' OR
            raw_message LIKE '%خصم%' OR
            raw_message LIKE '%شراء%' OR
            raw_message LIKE '%سحب%' OR
            raw_message LIKE '%مبلغ صادر%'
          );
      ''',
    );
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'unknown'
        WHERE direction IS NULL;
      ''',
    );
  }

  Future<void> _repairBankCaptureTimestampDrift() async {
    // Older backend builds interpreted SMS body times as UTC instead of the
    // device timezone, and briefly trusted stale AI years such as 2024. A bank
    // capture cannot happen far in the future, and SMS dates older than the
    // import time by a month are safer as received-at timestamps than as
    // misleading ledger dates.
    await customUpdate(
      '''
        UPDATE transactions
        SET occurred_at = COALESCE(sms_received_at, created_at),
            comparison_timestamp = COALESCE(sms_received_at, created_at),
            comparison_timestamp_source = 'received_at',
            transaction_time_from_sms = NULL,
            sms_received_at = COALESCE(sms_received_at, created_at),
            updated_at = ?
        WHERE source = 'bank'
          AND status IN ('confirmed', 'pending')
          AND comparison_timestamp_source = 'sms_body'
          AND (
            julianday(occurred_at) - julianday(created_at) > (10.0 / 1440.0)
            OR julianday(created_at) - julianday(occurred_at) > 31.0
          );
      ''',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
      ],
    );
  }

  Future<String?> _categoryIdByKey(String key) async {
    final row = await customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  static String normalizeMerchant(String rawMerchant) =>
      _normalizeMerchant(rawMerchant);

  static String _normalizeMerchant(String rawMerchant) {
    return rawMerchant
        .toUpperCase()
        .replaceAll(RegExp(r'[0-9]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
