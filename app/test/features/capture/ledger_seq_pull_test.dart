// WP-4: sequence pull + §4.11 identity rule + integrity quarantine.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _uid = 'test-user-id';

class _SeqRemote implements LedgerRemoteSource, SeqRemote {
  List<Map<String, dynamic>> rows = [];
  String epoch = 'e1';
  String? epochReason;
  int? headOverride;
  bool ignoreAfter = false; // a misbehaving server that re-sends old rows
  int seqCalls = 0;
  int legacyCalls = 0;
  final seenAfter = <int>[];

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    legacyCalls++;
    final sorted = [...rows]..sort((a, b) {
        final t = normalizeCursorTimestamp(a['updated_at'])
            .compareTo(normalizeCursorTimestamp(b['updated_at']));
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return sorted
        .where((r) {
          if (after.id.isEmpty) return true;
          final c = normalizeCursorTimestamp(r['updated_at'])
              .compareTo(after.updatedAt);
          return c > 0 ||
              (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) async {
    seqCalls++;
    seenAfter.add(afterSeq);
    final sorted = rows
        .where((r) => ignoreAfter || (r['sync_seq'] as int) > afterSeq)
        .toList()
      ..sort((a, b) => (a['sync_seq'] as int).compareTo(b['sync_seq'] as int));
    return sorted.take(limit).toList();
  }

  @override
  Future<SyncHead?> fetchHead(String userId) async => SyncHead(
        lastSeq: headOverride ??
            rows.fold<int>(
                0, (m, r) => (r['sync_seq'] as int) > m ? r['sync_seq'] as int : m),
        epoch: epoch,
        epochReason: epochReason,
      );
}

Map<String, dynamic> _row(
  String id,
  int seq, {
  String? cri,
  String? payloadId,
  String updatedAt = '2026-01-01T10:00:00.000Z',
}) =>
    {
      'id': id,
      'sync_seq': seq,
      'client_request_id': cri,
      'source_payload_id': payloadId,
      'amount_text': '10.0',
      'balance_after_text': null,
      'foreign_amount_text': null,
      'foreign_currency': null,
      'currency': 'SAR',
      'transaction_type': 'expense',
      'source': 'ios_shortcut',
      'merchant': 'm',
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': updatedAt,
      'confidence': 0.9,
    };

LedgerSyncService _svc(
  AppDatabase db,
  _SeqRemote remote, {
  ServerCapabilityState? cap = ServerCapabilityState.verified,
  int pageSize = 200,
}) =>
    LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => true,
      remoteSource: remote,
      getAuthUserId: () async => _uid,
      pageSize: pageSize,
      mayEgress: () async => true,
      seqGate: cap == null
          ? null
          : SeqPullGate(db: db, capability: () async => cap, remote: remote),
    );

Future<void> _insertLocal(AppDatabase db, String id, {String? serverId}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
      raw_message, parse_confidence, status, created_at, updated_at, server_id)
    VALUES ('$id', 5.0, 'SAR', 'payment', 'bank', '$now', '', 0.9,
      'confirmed', '$now', '$now', ${sqlNullableString(serverId)});
  ''');
  await backfillNonPlanningMoneyV30(db);
}

void main() {
  late AppDatabase db;
  late _SeqRemote remote;

  setUp(() async {
    db = await seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));
    remote = _SeqRemote();
  });
  tearDown(() => db.close());

  Future<List<String>> localIds() async => [
        for (final r in await db
            .customSelect('SELECT id FROM transactions ORDER BY id;')
            .get())
          r.read<String>('id'),
      ];

  group('sequence pull', () {
    test('pulls in sync_seq order across pages and persists the seq cursor',
        () async {
      // sync_seq order differs from updated_at/id order (clock-skewed row).
      remote.rows = [
        _row('s-c', 3, updatedAt: '2026-01-01T10:00:03.000Z'),
        _row('s-a', 1, updatedAt: '2026-01-01T10:00:09.000Z'),
        _row('s-b', 2, updatedAt: '2026-01-01T10:00:01.000Z'),
      ];
      final r = await _svc(db, remote, pageSize: 2).pull();
      expect(r.status, SyncPullStatus.completed);
      expect(r.imported, 3);
      expect(remote.seenAfter, [0, 2]);
      expect(remote.legacyCalls, 0);
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 3);

      // Incremental: only newer rows; an old-updated_at row written late
      // (higher seq) is still pulled.
      remote.rows.add(_row('s-d', 4, updatedAt: '2020-01-01T00:00:00.000Z'));
      final r2 = await _svc(db, remote).pull();
      expect(r2.imported, 1);
      expect(remote.seenAfter.last, 3);
    });

    test('crash mid-page: page and cursor are atomic (both or neither)',
        () async {
      remote.rows = [_row('s-a', 1), _row('s-b', 2)];
      var admitted = true;
      // Admission is lost after rows were applied but before the cursor write.
      var checks = 0;
      final r = await _svc(db, remote).pull(isAdmitted: () {
        checks++;
        if (checks >= 3) admitted = false;
        return admitted;
      });
      expect(r.status, SyncPullStatus.failed);
      expect(await localIds(), isEmpty);
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 0);

      // Re-apply is idempotent.
      final again = await _svc(db, remote).pull();
      expect(again.imported, 2);
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 2);
      await _svc(db, remote).pull();
      expect((await localIds()).length, 2);
    });

    test('capability false (unsupported) keeps the legacy timestamp pull',
        () async {
      remote.rows = [_row('s-a', 1)];
      final r =
          await _svc(db, remote, cap: ServerCapabilityState.unsupported).pull();
      expect(r.imported, 1);
      expect(remote.seqCalls, 0);
      expect(remote.legacyCalls, greaterThan(0));
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 0);
      expect((await readSyncCursor(db, 'ledger_transactions')).id, 's-a');
    });

    test('no capability hook (default) keeps the legacy pull', () async {
      remote.rows = [_row('s-a', 1)];
      await _svc(db, remote, cap: null).pull();
      expect(remote.seqCalls, 0);
      expect(remote.legacyCalls, greaterThan(0));
    });

    test('capability unknown pulls nothing and reports a typed stop', () async {
      remote.rows = [_row('s-a', 1)];
      final r =
          await _svc(db, remote, cap: ServerCapabilityState.unknown).pull();
      expect(r.stopped, LedgerPullStop.capabilityUnknown);
      expect(r.status, SyncPullStatus.failed);
      expect(remote.seqCalls + remote.legacyCalls, 0);
    });

    test(
        'epoch is recorded first, then a mismatch stops the pull (no rebootstrap)',
        () async {
      remote.rows = [_row('s-a', 1)];
      await _svc(db, remote).pull();
      expect((await readRecordedSyncEpoch(db, _uid))!.epoch, 'e1');

      remote
        ..epoch = 'e2'
        ..epochReason = 'purge';
      remote.rows.add(_row('s-b', 2));
      final calls = remote.seqCalls;
      final r = await _svc(db, remote).pull();
      expect(r.stopped, LedgerPullStop.epochMismatch);
      expect(r.status, SyncPullStatus.failed);
      expect(remote.seqCalls, calls);
      expect(await localIds(), hasLength(1));
      // The recorded epoch is NOT overwritten (WP-7 owns that).
      expect((await readRecordedSyncEpoch(db, _uid))!.epoch, 'e1');
    });

    test('a non-advancing sync_seq page fails instead of looping', () async {
      remote.rows = [_row('s-a', 3)];
      await _svc(db, remote).pull();
      remote.ignoreAfter = true;
      remote.headOverride = 10;
      final r = await _svc(db, remote).pull();
      expect(r.status, SyncPullStatus.failed);
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 3);
    });
  });

  group('identity (§4.11)', () {
    test('new row with client_request_id gets local id = client_request_id',
        () async {
      remote.rows = [_row('srv-1', 1, cri: 'cap-123')];
      await _svc(db, remote).pull();
      expect(await localIds(), ['cap-123']);
      final r = await db
          .customSelect('SELECT server_id FROM transactions;')
          .getSingle();
      expect(r.read<String>('server_id'), 'srv-1');
    });

    test('legacy row without client_request_id still gets a generated id',
        () async {
      remote.rows = [_row('srv-1', 1)];
      await _svc(db, remote).pull();
      expect((await localIds()).single, isNot('srv-1'));
    });

    test(
        'local row whose id == client_request_id (lost ACK) is adopted, not duplicated',
        () async {
      await _insertLocal(db, 'cap-9');
      remote.rows = [_row('srv-9', 1, cri: 'cap-9')];
      final r = await _svc(db, remote).pull();
      expect(r.imported, 0);
      expect(r.updated, 1);
      expect(await localIds(), ['cap-9']);
      final row = await db
          .customSelect("SELECT server_id FROM transactions WHERE id='cap-9';")
          .getSingle();
      expect(row.read<String>('server_id'), 'srv-9');
    });

    test('server_id wins over client_request_id', () async {
      await _insertLocal(db, 'local-a', serverId: 'srv-1');
      remote.rows = [_row('srv-1', 1, cri: 'cap-other')];
      final r = await _svc(db, remote).pull();
      expect(r.updated, 1);
      expect(await localIds(), ['local-a']);
    });

    test(
        'legacy payload marker still resolves when there is no client_request_id',
        () async {
      await _insertLocal(db, 'local-m');
      await DriftDedupStore(db).mark(
        'capture_payload:p1',
        transactionId: 'local-m',
        occurredAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      remote.rows = [_row('srv-1', 1, payloadId: 'p1')];
      final r = await _svc(db, remote).pull();
      expect(r.updated, 1);
      expect(await localIds(), ['local-m']);
    });

    test(
        'incompatible collision is quarantined as integrity, never a random id; cursor advances',
        () async {
      await _insertLocal(db, 'cap-1', serverId: 'srv-OTHER');
      remote.rows = [
        _row('srv-1', 1, cri: 'cap-1'),
        _row('srv-2', 2, cri: 'cap-2'),
      ];
      final r = await _svc(db, remote).pull();
      expect(r.imported, 1);
      expect(await localIds(), ['cap-1', 'cap-2']);
      expect(await ledgerIntegrityQuarantineCount(db), 1);
      final parked = await db
          .customSelect('SELECT server_id, reason FROM parked_child_rows;')
          .getSingle();
      expect(parked.read<String>('server_id'), 'srv-1');
      expect(parked.read<String>('reason'), 'integrity');
      expect(await readSeqCursor(db, _uid, 'ledger_transactions'), 2);

      // The colliding local row is untouched and is not retried into a
      // replacement id on the next pull.
      await _svc(db, remote).pull();
      expect(await localIds(), ['cap-1', 'cap-2']);
      expect(await ledgerIntegrityQuarantineCount(db), 1);
    });

    test('collision is also quarantined on the legacy timestamp path',
        () async {
      await _insertLocal(db, 'cap-1', serverId: 'srv-OTHER');
      remote.rows = [_row('srv-1', 1, cri: 'cap-1')];
      await _svc(db, remote, cap: null).pull();
      expect(await localIds(), ['cap-1']);
      expect(await ledgerIntegrityQuarantineCount(db), 1);
    });
  });
}
