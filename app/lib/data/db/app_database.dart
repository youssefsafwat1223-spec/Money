import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import 'database_key_store.dart';
import 'database_seed.dart';
import 'sql_value_codec.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase._(
    DatabaseConnection connection, {
    required this.keyStore,
    required this.isEncrypted,
  }) : super.connect(connection);

  final DatabaseKeyStore keyStore;
  final bool isEncrypted;

  @override
  int get schemaVersion => 1;

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
    await customStatement('PRAGMA user_version = 1;');
    await _createSchema();
    await _seedIfNeeded();
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
      isolateSetup: () async {
        if (Platform.isAndroid) {
          await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
        }
      },
      setup: (database) {
        database.execute("PRAGMA key = '${escapeSqlString(key)}';");
        database.execute('PRAGMA foreign_keys = ON;');
        final cipherVersion = database.select('PRAGMA cipher_version;');
        if (cipherVersion.isEmpty) {
          throw StateError(
            'SQLCipher library is not available. The database would not be encrypted.',
          );
        }
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
        db_encryption_key_ref TEXT NOT NULL
      );
    ''');
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
            id, country, currency, language, theme, input_method, notifications_json, db_encryption_key_ref
          )
          VALUES (?, 'SA', 'SAR', 'ar', 'system', 'auto', '{"captureReview":true,"captureLight":true,"budgetWarning":true,"budgetOver":true,"achievements":true,"streakReminder":true,"quietHoursStartHour":23,"quietHoursEndHour":8}', ?);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(keyRef),
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
