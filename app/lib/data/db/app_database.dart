import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import 'database_key_store.dart';
import 'database_seed.dart';
import 'sql_value_codec.dart';

const int _targetSchemaVersion = 2;

class AppDatabase extends GeneratedDatabase {
  AppDatabase._(
    DatabaseConnection connection, {
    required this.keyStore,
    required this.isEncrypted,
  }) : super.connect(connection);

  final DatabaseKeyStore keyStore;
  final bool isEncrypted;

  @override
  int get schemaVersion => _targetSchemaVersion;

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

  Future<void> initialize() async {
    await customStatement('PRAGMA foreign_keys = ON;');
    await _createSchema();
    await _runCompatibilityMigrations();
    await _seedIfNeeded();
    await customStatement('PRAGMA user_version = $_targetSchemaVersion;');
  }

  @override
  Future<void> close() => executor.close();

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
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        target_amount REAL NOT NULL,
        saved_amount REAL NOT NULL,
        deadline TEXT NULL,
        vault_skin TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL
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
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE
      );
    ''');

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

    await customStatement('''
      CREATE TABLE IF NOT EXISTS user_settings(
        id TEXT PRIMARY KEY,
        country TEXT NOT NULL,
        currency TEXT NOT NULL,
        language TEXT NOT NULL,
        theme TEXT NOT NULL,
        input_method TEXT NOT NULL,
        notifications_json TEXT NOT NULL,
        db_encryption_key_ref TEXT NOT NULL,
        privacy_mode_enabled INTEGER NOT NULL DEFAULT 0
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
        updated_at TEXT NOT NULL
      );
    ''');
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
    // v2: ربط المعاملات/الاشتراكات بالحساب (multi-currency accounts).
    await _ensureColumn('transactions', 'account_id', 'TEXT NULL');
    await _ensureColumn('subscriptions', 'account_id', 'TEXT NULL');
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
        await count('merchant_category_map') == 0) {
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

    if (await count('goals') == 0) {
      for (final goal in DatabaseSeed.suggestedGoals) {
        await _insertGoal(goal);
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
          VALUES (?, 'SA', 'SAR', 'ar', 'system', 'auto', '{"captureReview":true,"captureLight":true,"budgetWarning":true,"budgetOver":true,"achievements":true,"streakReminder":true,"weeklyReport":true,"subscriptionReminder":true,"goalMilestone":true,"quietHoursStartHour":23,"quietHoursEndHour":8,"notifiedGoalMilestones":{}}', ?, 0);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(keyRef),
        ],
      );
    }

    await _ensureDefaultAccount();
  }

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
  }

  Future<void> _ensureInternalCategories() async {
    for (final category in DatabaseSeed.categories.where((it) => it.sort < 0)) {
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

  Future<void> _insertGoal(GoalEntity goal) async {
    await customStatement('''
      INSERT INTO goals(
        id, name, target_amount, saved_amount, deadline, vault_skin, status, created_at
      )
      VALUES (
        ${sqlString(goal.id)},
        ${sqlString(goal.name)},
        ${goal.targetAmount},
        ${goal.savedAmount},
        ${sqlNullableString(goal.deadline == null ? null : dateTimeToSql(goal.deadline!))},
        ${sqlString(goal.vaultSkin)},
        ${sqlString(goal.status)},
        ${sqlString(dateTimeToSql(goal.createdAt))}
      );
    ''');
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
