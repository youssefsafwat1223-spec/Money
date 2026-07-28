import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

const _t = '2026-07-01T00:00:00.000Z';

Future<void> _insertAccount(
  AppDatabase db, {
  required String id,
  double? creditLimit,
  String? walletProvider,
  bool excludeFromTotals = false,
  String? metadata,
}) async {
  await db.customStatement(
    "INSERT INTO accounts(id, name, currency, type, credit_limit, "
    "wallet_provider, exclude_from_totals, metadata, is_default, sort_order, "
    "created_at, updated_at) VALUES ('$id', 'Acc $id', 'SAR', 'bank', "
    "${creditLimit ?? 'NULL'}, ${walletProvider == null ? 'NULL' : "'$walletProvider'"}, "
    "${excludeFromTotals ? 1 : 0}, ${metadata == null ? 'NULL' : "'$metadata'"}, "
    "0, 5, '$_t', '$_t');",
  );
}

Future<void> _insertCategory(
  AppDatabase db, {
  required String id,
  required String key,
  String? deletedAt,
}) async {
  await db.customStatement(
    "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
    "sort_order, deleted_at) VALUES ('$id', '$key', 'خاصة', 'tag', '#111111', "
    "0, 900, ${deletedAt == null ? 'NULL' : "'$deletedAt'"});",
  );
}

Future<void> _insertCard(
  AppDatabase db, {
  required String id,
  String? deletedAt,
}) async {
  await db.customStatement(
    "INSERT INTO cards(id, account_id, nickname, last4, network, source, "
    "color_theme, accent_hex, created_at, updated_at, deleted_at) "
    "VALUES ('$id', NULL, 'بطاقتي', '4242', 'visa', 'manual', 'midnight', "
    "'#00E5FF', '$_t', '$_t', ${deletedAt == null ? 'NULL' : "'$deletedAt'"});",
  );
}

Future<void> _insertSenderMapping(
  AppDatabase db, {
  required String id,
  required String source,
  String status = 'pending',
}) async {
  final confirmedAt = status == 'confirmed' ? "'$_t'" : 'NULL';
  final rejectedAt = status == 'rejected' ? "'$_t'" : 'NULL';
  await db.customStatement(
    "INSERT INTO sender_bank_mappings(id, sender_id, normalized_sender_id, "
    "bank_key, suggested_bank_name, suggested_country, confidence, status, "
    "source, first_seen_at, last_seen_at, confirmed_at, rejected_at, "
    "created_at, updated_at) VALUES ('$id', 'SND-$id', 'snd-$id', 'alrajhi', "
    "'Al Rajhi', 'SA', 0.9, '$status', '$source', '$_t', '$_t', $confirmedAt, "
    "$rejectedAt, '$_t', '$_t');",
  );
}

Future<int> _count(AppDatabase db, String table, [String where = '']) async {
  final sql = where.isEmpty
      ? 'SELECT COUNT(*) AS n FROM $table;'
      : 'SELECT COUNT(*) AS n FROM $table WHERE $where;';
  return (await db.customSelect(sql).getSingle()).read<int>('n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase source;
  late AppDatabase target;

  setUp(() async {
    source = await _openDb();
    target = await _openDb();
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  Future<void> roundTrip() async {
    final snapshot = await BackupSnapshotBuilder(source).build();
    await RestoreBackupUseCase(target)(snapshot);
  }

  test('new account fields survive a round trip', () async {
    await _insertAccount(
      source,
      id: 'acc-rich',
      creditLimit: 5000,
      walletProvider: 'vodafone_cash',
      excludeFromTotals: true,
      metadata: '{"instapay_fee":1}',
    );

    await roundTrip();

    final row = await target
        .customSelect("SELECT * FROM accounts WHERE id = 'acc-rich';")
        .getSingle();
    expect(row.read<double>('credit_limit'), 5000);
    expect(row.read<String>('wallet_provider'), 'vodafone_cash');
    expect(row.read<int>('exclude_from_totals'), 1);
    expect(row.read<String>('metadata'), '{"instapay_fee":1}');
  });

  test('inactive/archived category round-trips with its deleted_at preserved',
      () async {
    await _insertCategory(source,
        id: 'cat-archived', key: 'custom_archived', deletedAt: _t);

    await roundTrip();

    final row = await target
        .customSelect("SELECT * FROM categories WHERE id = 'cat-archived';")
        .getSingle();
    expect(row.readNullable<String>('deleted_at'), isNotNull,
        reason: 'archival state is meaningful user data');
  });

  test('inactive/archived card round-trips with its deleted_at preserved',
      () async {
    await _insertCard(source, id: 'card-archived', deletedAt: _t);

    await roundTrip();

    final row = await target
        .customSelect("SELECT * FROM cards WHERE id = 'card-archived';")
        .getSingle();
    expect(row.read<String>('last4'), '4242');
    expect(row.readNullable<String>('deleted_at'), isNotNull);
  });

  test('a transaction referencing a soft-deleted category stays resolvable',
      () async {
    await _insertCategory(source,
        id: 'cat-hist', key: 'custom_hist', deletedAt: _t);
    await source.customStatement(
      "INSERT INTO transactions(id, amount, currency, category_id, type, "
      "source, occurred_at, raw_message, parse_confidence, status, "
      "created_at, updated_at) VALUES ('tx-hist', 25, 'SAR', 'cat-hist', "
      "'payment', 'bank', '$_t', 'raw', 1.0, 'confirmed', '$_t', '$_t');",
    );

    await roundTrip();

    final joined = await target
        .customSelect(
          "SELECT c.id AS cid FROM transactions t "
          "LEFT JOIN categories c ON c.id = t.category_id "
          "WHERE t.id = 'tx-hist';",
        )
        .getSingle();
    expect(joined.readNullable<String>('cid'), 'cat-hist',
        reason: 'omitting soft-deleted categories would orphan this reference');
  });

  test('only user-authored sender mappings are backed up; all remote excluded',
      () async {
    // Backed up: user-created + user-decided non-remote rows.
    await _insertSenderMapping(source, id: 'usr', source: 'user_manual');
    await _insertSenderMapping(source,
        id: 'confirmed-gemini', source: 'gemini', status: 'confirmed');
    // Excluded: untouched remote seed, untouched pending gemini, AND — the key
    // tightening — a REMOTE row that carries a confirmed/rejected status
    // (confirm/reject never rewrite source, and sync-down can deliver a
    // server row already confirmed, so status alone can't prove local origin).
    await _insertSenderMapping(source, id: 'remote-seed', source: 'remote');
    await _insertSenderMapping(source,
        id: 'pending-gemini', source: 'gemini', status: 'pending');
    await _insertSenderMapping(source,
        id: 'remote-confirmed', source: 'remote', status: 'confirmed');
    await _insertSenderMapping(source,
        id: 'remote-rejected', source: 'remote', status: 'rejected');

    final snapshot = await BackupSnapshotBuilder(source).build();
    final mapped = (snapshot['tables']
        as Map<String, dynamic>)['sender_bank_mappings'] as List;
    final ids = mapped.map((row) => (row as Map)['id']).toSet();
    expect(ids, containsAll(<String>['usr', 'confirmed-gemini']));
    expect(
        ids,
        isNot(anyElement(isIn(<String>[
          'remote-seed',
          'pending-gemini',
          'remote-confirmed',
          'remote-rejected',
        ]))),
        reason: 'no remote row may be backed up, whatever its status');

    await RestoreBackupUseCase(target)(snapshot);
    expect(await _count(target, 'sender_bank_mappings', "id = 'usr'"), 1);
    expect(await _count(target, 'sender_bank_mappings', "source = 'remote'"), 0,
        reason: 'restored device holds no remote rows from the backup');
  });

  test('malformed v3 backup is rejected BEFORE any destructive delete',
      () async {
    await target.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at) VALUES ('target-marker', 9, 'SAR', 'payment', 'bank', "
      "'$_t', 'raw', 1.0, 'confirmed', '$_t', '$_t');",
    );

    final bad = {
      'schemaVersion': 3,
      'tables': {
        'transactions': 'not-a-list', // structurally invalid
      },
    };

    await expectLater(
      RestoreBackupUseCase(target)(bad),
      throwsA(isA<BackupException>()),
    );
    expect(await _count(target, 'transactions', "id = 'target-marker'"), 1,
        reason: 'validation must run before DELETE');
  });

  test('a v3 backup with an empty categories payload cannot wipe the catalog',
      () async {
    final catalogBefore = await _count(target, 'categories');
    expect(catalogBefore, greaterThan(0));

    final emptyCats = {
      'schemaVersion': 3,
      'tables': {
        'categories': <dynamic>[],
        'accounts': <dynamic>[],
      },
    };
    await expectLater(
      RestoreBackupUseCase(target)(emptyCats),
      throwsA(isA<BackupException>()),
    );
    expect(await _count(target, 'categories'), catalogBefore,
        reason: 'catalog must be intact — no delete may have run');

    // Missing key entirely is likewise rejected.
    final missingCats = {
      'schemaVersion': 3,
      'tables': {'accounts': <dynamic>[]},
    };
    await expectLater(
      RestoreBackupUseCase(target)(missingCats),
      throwsA(isA<BackupException>()),
    );
    expect(await _count(target, 'categories'), catalogBefore);
  });

  test('a mid-restore insertion failure rolls the entire restore back',
      () async {
    // A marker account in a table the snapshot DOES carry (accounts), so the
    // restore deletes it first — only a working rollback brings it back.
    await _insertAccount(target, id: 'target-acc-marker');
    final catalogBefore = await _count(target, 'categories');

    // Passes preflight (required tables present & non-empty, all lists of maps)
    // but the card row omits the NOT NULL `last4`, so the INSERT throws
    // mid-transaction — after accounts/categories were already deleted+inserted.
    final snapshot = {
      'schemaVersion': 3,
      'tables': {
        'accounts': [
          {
            'id': 'a1',
            'name': 'A',
            'currency': 'SAR',
            'type': 'bank',
            'created_at': _t,
            'updated_at': _t,
          }
        ],
        'categories': [
          {
            'id': 'cat-x',
            'key': 'custom_x',
            'name_ar': 'x',
            'icon': 'tag',
            'color': '#fff',
            'is_income': 0,
            'sort_order': 1,
          }
        ],
        // Preflight-only (never reached — cards fails first at restore index 2).
        'user_settings': [
          {'id': 's1'}
        ],
        'cards': [
          {'id': 'bad-card', 'network': 'visa', 'source': 'manual'},
        ],
      },
    };

    await expectLater(
      RestoreBackupUseCase(target)(snapshot),
      throwsA(isA<Object>()),
    );

    // Everything rolled back: the deleted marker account is restored, the
    // snapshot's own rows are gone, catalog intact, no partial card.
    expect(await _count(target, 'accounts', "id = 'target-acc-marker'"), 1,
        reason: 'the pre-restore account must survive a rolled-back restore');
    expect(await _count(target, 'accounts', "id = 'a1'"), 0);
    expect(await _count(target, 'categories'), catalogBefore);
    expect(await _count(target, 'cards', "id = 'bad-card'"), 0);
  });

  test('a truncated v3 backup missing a required table fails before delete',
      () async {
    await _insertAccount(target, id: 'target-acc-marker');
    final catalogBefore = await _count(target, 'categories');

    // Valid categories + accounts, but user_settings (required) is missing —
    // a truncated backup. Must be rejected before any DELETE runs.
    final truncated = {
      'schemaVersion': 3,
      'tables': {
        'categories': [
          {
            'id': 'cat-x',
            'key': 'custom_x',
            'name_ar': 'x',
            'icon': 'tag',
            'color': '#fff',
            'is_income': 0,
            'sort_order': 1,
          }
        ],
        'accounts': [
          {
            'id': 'a1',
            'name': 'A',
            'currency': 'SAR',
            'type': 'bank',
            'created_at': _t,
            'updated_at': _t,
          }
        ],
      },
    };

    await expectLater(
      RestoreBackupUseCase(target)(truncated),
      throwsA(isA<BackupException>()),
    );
    expect(await _count(target, 'accounts', "id = 'target-acc-marker'"), 1,
        reason: 'no delete may have run');
    expect(await _count(target, 'categories'), catalogBefore);
  });

  test('v2 restore preserves tables absent from the snapshot', () async {
    // Target has a custom category and a card the v2 snapshot never captured.
    await _insertCategory(target, id: 'cat-keep', key: 'custom_keep');
    await _insertCard(target, id: 'card-keep');
    final catalogBefore = await _count(target, 'categories');

    // A v2 snapshot: real accounts/transactions, but no cards/categories keys.
    final v2 = {
      'schemaVersion': 2,
      'tables': {
        'accounts': <dynamic>[],
        'transactions': <dynamic>[],
      },
    };
    await RestoreBackupUseCase(target)(v2);

    expect(await _count(target, 'categories', "id = 'cat-keep'"), 1,
        reason: 'v2 has no categories key → conditional delete must skip it');
    expect(await _count(target, 'cards', "id = 'card-keep'"), 1);
    expect(await _count(target, 'categories'), catalogBefore);
  });

  test('coverage guard: every schema table is backed up or excluded on purpose',
      () async {
    final rows = await source
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%';",
        )
        .get();
    for (final row in rows) {
      final table = row.read<String>('name');
      if (table.endsWith('_new')) continue; // transient migration temps
      final classified = BackupSnapshotBuilder.backedUpTables.contains(table) ||
          BackupSnapshotBuilder.intentionallyExcluded.contains(table);
      expect(classified, isTrue,
          reason: 'schema table "$table" is neither backed up nor in '
              'intentionallyExcluded — classify it (MALI-014).');
    }
  });
}
