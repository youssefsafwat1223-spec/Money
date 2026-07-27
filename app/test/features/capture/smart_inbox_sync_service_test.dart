import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// In-memory remote source — returns the rows you hand it; no network calls.
class _FakeRemoteSource implements SmartInboxRemoteSource {
  _FakeRemoteSource({
    this.activeRows = const [],
    this.tombstoneRows = const [],
    this.throwOnPush = false,
  });

  final List<Map<String, dynamic>> activeRows;
  final List<Map<String, dynamic>> tombstoneRows;
  final bool throwOnPush;
  final List<(String, String)> pushed = [];

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit = 200}) async =>
      activeRows;

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones({int limit = 200}) async =>
      tombstoneRows;

  @override
  Future<void> pushStatus(String serverId, String status) async {
    if (throwOnPush) throw Exception('offline');
    pushed.add((serverId, status));
  }
}

Map<String, dynamic> _serverRow({
  required String id,
  String type = 'needs_review',
  String title = 'Review this',
  String? body,
  String status = 'open',
  double? confidence,
  String? transactionId,
  String? payloadId,
  Map<String, dynamic>? metadata,
  String? updatedAt,
}) =>
    {
      'id': id,
      'transaction_id': transactionId,
      'payload_id': payloadId,
      'type': type,
      'title': title,
      'body': body,
      'status': status,
      'confidence': confidence,
      'metadata': metadata,
      'created_at': '2026-07-03T00:00:00.000Z',
      'updated_at': updatedAt ?? '2026-07-03T00:00:00.000Z',
    };

SmartInboxSyncService _svc(
  AppDatabase db, {
  bool flagOn = true,
  bool signedIn = true,
  List<Map<String, dynamic>> activeRows = const [],
  List<Map<String, dynamic>> tombstoneRows = const [],
}) =>
    SmartInboxSyncService(
      db: db,
      isPullEnabled: () => flagOn,
      getAuthUserId: () async => signedIn ? 'user-123' : null,
      remoteSource: _FakeRemoteSource(
        activeRows: activeRows,
        tombstoneRows: tombstoneRows,
      ),
    );

Future<List<Map<String, dynamic>>> _allLocalRows(AppDatabase db) async {
  final rows = await db.customSelect('SELECT * FROM smart_inbox_items;').get();
  return rows.map((r) => r.data).toList();
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  // ── flag / auth guards ────────────────────────────────────────────────────

  test('pull does nothing when flag is OFF', () async {
    final svc = _svc(
      db,
      flagOn: false,
      activeRows: [_serverRow(id: 'srv-1')],
    );
    final result = await svc.pull();
    expect(result.imported, 0);
    expect(result.updated, 0);
    expect(result.tombstoned, 0);
    expect((await _allLocalRows(db)).length, 0);
  });

  test('pull does nothing for guest (no auth session)', () async {
    final svc = _svc(
      db,
      signedIn: false,
      activeRows: [_serverRow(id: 'srv-1')],
    );
    final result = await svc.pull();
    expect(result.imported, 0);
    expect((await _allLocalRows(db)).length, 0);
  });

  // ── import ────────────────────────────────────────────────────────────────

  test('signed-in + flag ON imports a needs_review item', () async {
    final svc = _svc(db, activeRows: [_serverRow(id: 'srv-needs-review')]);
    final result = await svc.pull();
    expect(result.imported, 1);

    final rows = await _allLocalRows(db);
    expect(rows.length, 1);
    expect(rows.first['server_id'], 'srv-needs-review');
    expect(rows.first['type'], 'needs_review');
    expect(rows.first['title'], 'Review this');
    expect(rows.first['status'], 'open');
  });

  test('pulling same server_id twice does not create a duplicate', () async {
    final row = _serverRow(id: 'srv-dupe');
    final svc = _svc(db, activeRows: [row]);
    await svc.pull();
    await svc.pull(); // second pull of identical row
    expect((await _allLocalRows(db)).length, 1);
  });

  // ── tombstone ────────────────────────────────────────────────────────────

  test('server tombstone marks local item as dismissed', () async {
    // First pull imports the row.
    await _svc(db, activeRows: [_serverRow(id: 'srv-tbs')]).pull();
    expect((await _allLocalRows(db)).length, 1);

    // Second pull with tombstone.
    final result = await _svc(
      db,
      activeRows: [],
      tombstoneRows: [
        {'id': 'srv-tbs', 'deleted_at': '2026-07-03T01:00:00.000Z'}
      ],
    ).pull();
    expect(result.tombstoned, 1);

    final rows = await _allLocalRows(db);
    expect(rows.first['status'], 'dismissed');
  });

  // ── dismissed_locally guard ───────────────────────────────────────────────

  test('locally dismissed item is not resurrected by server re-open', () async {
    // Import the row first.
    await _svc(db, activeRows: [_serverRow(id: 'srv-local-dismiss')]).pull();

    // Simulate user dismissing locally.
    await db.customStatement(
      "UPDATE smart_inbox_items SET dismissed_locally = 1 "
      "WHERE server_id = 'srv-local-dismiss';",
    );

    // Server still sends the row as 'open' with a newer updated_at.
    final result = await _svc(
      db,
      activeRows: [
        _serverRow(
          id: 'srv-local-dismiss',
          status: 'open',
          updatedAt: '2026-07-03T02:00:00.000Z',
        )
      ],
    ).pull();
    expect(result.updated, 0);

    final rows = await _allLocalRows(db);
    // dismissed_locally still set; status unchanged.
    expect(rows.first['dismissed_locally'], 1);
  });

  // ── all supported types ──────────────────────────────────────────────────

  test('all five supported types are imported', () async {
    final types = [
      'needs_review',
      'suspicious_duplicate',
      'low_confidence',
      'budget_warning',
      'insight',
    ];
    final rows = types
        .asMap()
        .entries
        .map(
          (e) => _serverRow(id: 'srv-type-${e.key}', type: e.value),
        )
        .toList();

    final result = await _svc(db, activeRows: rows).pull();
    expect(result.imported, 5);
    expect((await _allLocalRows(db)).length, 5);
  });

  // ── unknown type ─────────────────────────────────────────────────────────

  test('unknown type from server is skipped gracefully without error',
      () async {
    final svc = _svc(
      db,
      activeRows: [_serverRow(id: 'srv-unknown', type: 'future_unknown_type')],
    );
    final result = await svc.pull();
    expect(result.imported, 0);
    expect((await _allLocalRows(db)).length, 0);
  });

  // ── metadata storage ─────────────────────────────────────────────────────

  test('metadata is stored as a JSON string', () async {
    final svc = _svc(
      db,
      activeRows: [
        _serverRow(
          id: 'srv-meta',
          metadata: {'budget_id': 'bgt-001', 'overage': 50.0},
        )
      ],
    );
    await svc.pull();

    final rows = await _allLocalRows(db);
    final decoded = jsonDecode(rows.first['metadata_json'] as String)
        as Map<String, dynamic>;
    expect(decoded['budget_id'], 'bgt-001');
    expect(decoded['overage'], 50.0);
  });

  // ── S3 gap#1: dismiss/resolve push (server-authored, specialized) ──────────

  test('offline dismiss queues pending_sync then pushes and clears the flag',
      () async {
    final fake = _FakeRemoteSource(activeRows: [_serverRow(id: 'srv-1')]);
    final svc = SmartInboxSyncService(
      db: db,
      isPullEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      remoteSource: fake,
    );
    await svc.pull(); // seed one open item locally

    // Offline user action → status + pending_sync=1, no network.
    await DriftSmartInboxRepository(db).dismiss('srv-1');
    var rows = await _allLocalRows(db);
    expect(rows.single['status'], 'dismissed');
    expect(rows.single['pending_sync'], 1);

    // Next sync cycle pushes it and clears the flag.
    final pushed = await svc.push();
    expect(pushed, 1);
    expect(fake.pushed, contains(('srv-1', 'dismissed')));
    rows = await _allLocalRows(db);
    expect(rows.single['pending_sync'], 0);
  });

  test('resolve pushes as resolved status', () async {
    final fake = _FakeRemoteSource(activeRows: [_serverRow(id: 'srv-9')]);
    final svc = SmartInboxSyncService(
      db: db,
      isPullEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      remoteSource: fake,
    );
    await svc.pull();
    await DriftSmartInboxRepository(db).resolve('srv-9');
    await svc.push();
    expect(fake.pushed, contains(('srv-9', 'resolved')));
  });

  test('push offline is a no-op that keeps pending_sync for retry', () async {
    final fake = _FakeRemoteSource(
      activeRows: [_serverRow(id: 'srv-2')],
      throwOnPush: true,
    );
    final svc = SmartInboxSyncService(
      db: db,
      isPullEnabled: () => true,
      getAuthUserId: () async => 'user-123',
      remoteSource: fake,
    );
    await svc.pull();
    await DriftSmartInboxRepository(db).dismiss('srv-2');

    final pushed = await svc.push(); // pushStatus throws → offline
    expect(pushed, 0);
    final rows = await _allLocalRows(db);
    expect(rows.single['pending_sync'], 1); // preserved for the next cycle
  });
}
