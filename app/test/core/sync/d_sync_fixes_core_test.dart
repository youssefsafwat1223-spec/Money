import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, PostgrestException;

/// Phase D sync fixes (core): D-4 failure classification + mapping backoff,
/// D-5 SyncStatus truth, D-8 keep-remote vs an in-flight push.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _Store implements SenderMappingRemoteStore {
  int upsertCalls = 0;
  Object? upsertError;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      const [];
  @override
  Future<List<Map<String, dynamic>>> upsert(
      List<Map<String, dynamic>> rows) async {
    upsertCalls++;
    if (upsertError != null) throw upsertError!;
    return rows;
  }
}

SyncStatus _derive(SyncQueueCounts counts) => SyncStatus.derive(
      counts: counts,
      health: {
        for (final d in SyncDomain.values)
          d: SyncDomainHealth(lastPushSuccessAt: DateTime.utc(2026, 6, 1, 11)),
      },
      cloudConsent: true,
      identity: SyncIdentity.authenticated,
      syncRunning: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async {
    outboxHasValidSession = () => false;
    await db.close();
  });

  group('D-4 failure classification', () {
    PostgrestException pg(String code) =>
        PostgrestException(message: 'm', code: code);

    test('42501 / 403 with a VALID session is a permanent permission denial',
        () {
      outboxHasValidSession = () => true;
      for (final code in ['42501', '403']) {
        final c = classifyOutboxError(pg(code));
        expect(c.reason, 'permission_denied', reason: code);
        expect(c.isPermanent, isTrue);
      }
    });

    test('42501 / 403 with NO valid session stays auth (re-armed later)', () {
      outboxHasValidSession = () => false;
      for (final code in ['42501', '403']) {
        expect(classifyOutboxError(pg(code)), OutboxFailureClass.auth);
      }
    });

    test('JWT errors are auth regardless of the session', () {
      outboxHasValidSession = () => true;
      for (final code in ['401', 'PGRST301', 'PGRST302', 'PGRST303']) {
        expect(classifyOutboxError(pg(code)), OutboxFailureClass.auth,
            reason: code);
      }
      expect(classifyOutboxError(const AuthException('expired')),
          OutboxFailureClass.auth);
    });

    test('a permission-denied dead letter is re-armable by Retry', () {
      expect(kRetryableDeadLetterSql, isNot(contains('permission_denied')));
    });

    test('an auth-rejected mapping backs off instead of re-sending every poll',
        () async {
      await db.customStatement('''
        INSERT INTO sender_bank_mappings(
          id, sender_id, normalized_sender_id, bank_key, suggested_bank_name,
          suggested_country, confidence, status, source, first_seen_at,
          last_seen_at, confirmed_at, created_at, updated_at, sync_status
        ) VALUES (
          'loc-a', 'a', 'a', 'localbank', 'Bank', 'SA', 0.9, 'confirmed',
          'user_manual', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
          'pending');
      ''');
      final store = _Store()
        ..upsertError = const PostgrestException(message: 'jwt', code: 'PGRST301');
      final service = SenderBankMappingSyncService(
        db: db,
        remoteStore: store,
        currentUserId: () => 'user-1',
        mayEgress: () async => true,
      );
      await service.push();
      final afterFirst = store.upsertCalls;
      expect(afterFirst, greaterThan(0));
      final row = (await db
              .customSelect('SELECT * FROM sender_bank_mappings;')
              .getSingle())
          .data;
      expect(row['sync_attempt_count'], 0, reason: 'no attempt consumed');
      expect(row['sync_status'], 'pending');
      expect(row['sync_next_retry_at'], isNotNull);

      await service.push();
      expect(store.upsertCalls, afterFirst,
          reason: 'inside the backoff window nothing is re-sent');
    });
  });

  group('D-5 SyncStatus truth', () {
    test('a conflict is needs-attention, never allSynced', () {
      expect(_derive(const SyncQueueCounts()).kind, SyncStatusKind.allSynced);
      final s = _derive(const SyncQueueCounts(conflicts: 2));
      // WP-8: a conflict is a decision, not a failure Retry could fix.
      expect(s.kind, SyncStatusKind.needsAttention);
      expect(s.needsAttention, 2);
    });

    test('server-less local rows awaiting backfill are not allSynced', () {
      final s = _derive(const SyncQueueCounts(unprovenLocalRows: 3));
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 3);
    });

    test('queueCounts reads conflicts and unproven rows from the database',
        () async {
      final base = await SyncHealth.queueCounts(db);
      expect(base.conflicts, 0);
      final baseUnproven = base.unprovenLocalRows;
      await db.customStatement('''
        INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
          raw_message, parse_confidence, status, created_at, updated_at)
        VALUES ('t-local', 1, 'SAR', 'payment', 'bank', '2026-06-01T00:00:00Z',
          '', 0.9, 'confirmed', '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z');
      ''');
      await db.customStatement('''
        INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
          raw_message, parse_confidence, status, created_at, updated_at, server_id,
          sync_status)
        VALUES ('t-conf', 1, 'SAR', 'payment', 'bank', '2026-06-01T00:00:00Z',
          '', 0.9, 'confirmed', '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z',
          'srv', 'conflict');
      ''');
      await db.customStatement('''
        INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
          raw_message, parse_confidence, status, created_at, updated_at)
        VALUES ('t-ignored', 1, 'SAR', 'payment', 'bank', '2026-06-01T00:00:00Z',
          '', 0.9, 'ignored', '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z');
      ''');
      final counts = await SyncHealth.queueCounts(db);
      expect(counts.conflicts, 1);
      expect(counts.unprovenLocalRows, baseUnproven + 1,
          reason: 'the ignored row does not await backfill');
      expect(_derive(counts).kind, isNot(SyncStatusKind.allSynced));
    });
  });

  group('D-8 keep-remote races an in-flight push', () {
    Future<void> seedTx(String id) => db.customStatement('''
      INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at, server_id,
        sync_status)
      VALUES ('$id', 1, 'SAR', 'payment', 'bank', '2026-06-01T00:00:00Z',
        '', 0.9, 'confirmed', '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z',
        'srv', 'conflict');
    ''');

    test('ledger: in_flight_seq set -> false, nothing changed', () async {
      await seedTx('t1');
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
          attempt_count, status, created_at, updated_at, op_seq, in_flight_seq)
        VALUES ('o1', 't1', 'update', '{}', 0, 'pending', '2026-06-01T00:00:00Z',
          '2026-06-01T00:00:00Z', 1, 1);
      ''');
      final resolver = UniversalConflictResolver(db: db, reEnqueue: const {});
      expect(await resolver.resolveKeepRemote('transaction', 't1'), isFalse);
      expect(
          (await db.customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox;').getSingle())
              .read<int>('n'),
          1);
      expect(
          (await db.customSelect("SELECT sync_status AS s FROM transactions WHERE id='t1';").getSingle())
              .read<String>('s'),
          'conflict');
      // Once the push settled (marker cleared) the resolution proceeds.
      await db.customStatement('UPDATE ledger_sync_outbox SET in_flight_seq = NULL;');
      expect(await resolver.resolveKeepRemote('transaction', 't1'), isTrue);
    });

    test('planning: in_flight_seq set -> false, nothing changed', () async {
      await db.customStatement('''
        INSERT INTO goals(id,name,target_amount,saved_amount,currency,
          target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
          vault_skin,status,created_at,server_id,sync_status)
        VALUES ('goal-1','goal',100,0,'EGP',10000,0,0,'classic','active',
          '2026-07-23T09:00:00.000Z','srv-g','conflict');
      ''');
      await db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, status, created_at, updated_at, op_seq,
          in_flight_seq)
        VALUES ('o1', 'goal', 'goal-1', 'update', '{}', 0, 'pending',
          '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z', 1, 1);
      ''');
      final resolver = UniversalConflictResolver(db: db, reEnqueue: const {});
      expect(await resolver.resolveKeepRemote('goal', 'goal-1'), isFalse);
      expect(
          (await db.customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;').getSingle())
              .read<int>('n'),
          1);
    });
  });
}
