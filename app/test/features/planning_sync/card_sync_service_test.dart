import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Shared in-memory "server" — lets us model two devices talking to one backend.
class _FakeRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  final tombstones = <String, List<Map<String, dynamic>>>{};
  int deletes = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows(String table,
      {int limit = 200}) async {
    return (rows[table]?.values ?? const <Map<String, dynamic>>[])
        .where((r) => r['deleted_at'] == null)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones(String table,
      {int limit = 200}) async {
    return (tombstones[table] ?? const <Map<String, dynamic>>[])
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      rows[table]?[localId];

  @override
  Future<void> tombstone(String table, String serverId) async {
    deletes++;
    final match = rows[table]?.values.firstWhere(
          (r) => r['id'] == serverId,
          orElse: () => <String, dynamic>{},
        );
    if (match == null || match.isEmpty) return;
    final at = DateTime.utc(2026, 7, 6).toIso8601String();
    match['deleted_at'] = at;
    match['updated_at'] = at;
    tombstones.putIfAbsent(table, () => []).add(Map.of(match));
  }

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    final localId = row['local_id'] as String;
    // Enforce the server's (user, account, last4) active-uniqueness.
    final clash = rows[table]?.values.firstWhere(
          (r) =>
              r['deleted_at'] == null &&
              r['local_account_id'] == row['local_account_id'] &&
              r['last4'] == row['last4'] &&
              r['local_id'] != localId,
          orElse: () => <String, dynamic>{},
        );
    if (clash != null && clash.isNotEmpty) {
      throw Exception('duplicate key value violates unique constraint (23505)');
    }
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': now};
  }
}

Future<AppDatabase> _openDb() => AppDatabase.open(
    executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

PlanningPushService _push(
        AppDatabase db, PlanningOutboxQueue q, _FakeRemote r) =>
    PlanningPushService(
      db: db,
      queue: q,
      isEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      remoteSink: r,
    );

PlanningPullService _pull(AppDatabase db, _FakeRemote r) => PlanningPullService(
      db: db,
      isEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      remoteSource: r,
    );

CardEntity _card(String acc, String last4,
        {CardSource source = CardSource.manual, String? nickname}) =>
    CardEntity(
      id: '',
      accountId: acc,
      last4: last4,
      network: CardNetwork.visa,
      source: source,
      nickname: nickname,
      createdAt: DateTime.utc(2026, 7, 1),
      updatedAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRemote remote;
  late PlanningOutboxQueue queue;
  late DriftCardRepository cards;

  setUp(() async {
    db = await _openDb();
    remote = _FakeRemote();
    queue = _queue(db);
    cards = DriftCardRepository(db, outboxQueue: queue);
  });
  tearDown(() async => db.close());

  test('manual + auto cards push to user_cards with correct source', () async {
    await cards.create(_card('acc-a', '1111', nickname: 'راتب'));
    await cards.create(_card('acc-a', '2222', source: CardSource.auto));

    final result = await _push(db, queue, remote).push();

    expect(result.failed, 0);
    expect(result.pushed, greaterThanOrEqualTo(2));
    final serverRows = remote.rows['user_cards']!;
    expect(serverRows.values.map((r) => r['source']),
        containsAll(['manual', 'auto']));
    expect(
        serverRows.values.firstWhere((r) => r['last4'] == '1111')['nickname'],
        'راتب');
  });

  test('card edit syncs (nickname/network update)', () async {
    final c = await cards.create(_card('acc-a', '1111'));
    await _push(db, queue, remote).push();
    await cards.update(c.copyWith(nickname: 'سفر', network: CardNetwork.mada));
    await _push(db, queue, remote).push();

    final row = remote.rows['user_cards']![c.id]!;
    expect(row['nickname'], 'سفر');
    expect(row['network'], 'mada');
  });

  test('card move between accounts syncs local_account_id', () async {
    final c = await cards.create(_card('acc-a', '1111'));
    await _push(db, queue, remote).push();
    await cards.moveToAccount(cardId: c.id, newAccountId: 'acc-b');
    await _push(db, queue, remote).push();

    expect(remote.rows['user_cards']![c.id]!['local_account_id'], 'acc-b');
  });

  test('card delete tombstones on server but keeps historical transactions',
      () async {
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "card_last4, account_id, occurred_at, raw_message, parse_confidence, "
      "status, created_at, updated_at) VALUES ('t1', 50, 'SAR', 'payment', "
      "'sms', '1111', 'acc-a', '2026-07-01T00:00:00.000Z', 'm', 1.0, "
      "'confirmed', '2026-07-01T00:00:00.000Z', '2026-07-01T00:00:00.000Z');",
    );
    final c = await cards.create(_card('acc-a', '1111'));
    await _push(db, queue, remote).push();
    await cards.delete(c.id);
    await _push(db, queue, remote).push();

    expect(remote.deletes, 1);
    expect(remote.rows['user_cards']![c.id]!['deleted_at'], isNotNull);
    // Transaction preserved.
    final txCount = await db
        .customSelect("SELECT COUNT(*) AS c FROM transactions WHERE id='t1';")
        .getSingle();
    expect(txCount.read<int>('c'), 1);
  });

  test('multi-device: card pushed by device A pulls into device B', () async {
    // Device A creates + pushes a card to the shared server.
    await cards.create(_card('acc-a', '9999', nickname: 'مشترك'));
    await _push(db, queue, remote).push();

    // Device B: a fresh local DB pulling from the same server.
    final dbB = await _openDb();
    addTearDown(() async => dbB.close());
    await _pull(dbB, remote).pull();

    final cardsB = DriftCardRepository(dbB);
    final byAccount = await cardsB.getByAccount('acc-a');
    expect(byAccount.map((c) => c.last4), contains('9999'));
    expect(byAccount.firstWhere((c) => c.last4 == '9999').nickname, 'مشترك');
  });

  test('duplicate pull does not duplicate the card', () async {
    await cards.create(_card('acc-a', '1111'));
    await _push(db, queue, remote).push();

    final dbB = await _openDb();
    addTearDown(() async => dbB.close());
    await _pull(dbB, remote).pull();
    await _pull(dbB, remote).pull(); // second pull must be idempotent

    final all = await DriftCardRepository(dbB).getAll();
    expect(all.where((c) => c.last4 == '1111'), hasLength(1));
  });
}
