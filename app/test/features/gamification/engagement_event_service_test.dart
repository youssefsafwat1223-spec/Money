import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/gamification/services/engagement_event_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

// MALI-024 — server-authoritative, idempotent engagement events.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Models the server RPC: awards per type, idempotent by event_id + business_key,
/// rejects unknown types / unsupported versions. Never accepts a client XP total.
class _FakeRecorder implements EngagementRemoteRecorder {
  int serverXp = 0;
  final Set<String> seenEvents = {};
  final Set<String> seenBusiness = {};
  int calls = 0;
  Object? failWith;

  @override
  Future<EngagementAck> record({
    required String eventId,
    required String eventType,
    required String occurredAt,
    String? businessKey,
    int eventVersion = 1,
  }) async {
    calls++;
    if (failWith != null) throw failWith!;
    if (eventVersion != 1) {
      throw const PostgrestException(message: 'unsupported version', code: '22023');
    }
    final award = kEngagementAward[eventType];
    if (award == null) {
      throw const PostgrestException(message: 'unknown type', code: '22023');
    }
    final dup =
        seenEvents.contains(eventId) || (businessKey != null && seenBusiness.contains(businessKey));
    if (!dup) {
      serverXp += award;
      seenEvents.add(eventId);
      if (businessKey != null) seenBusiness.add(businessKey);
    }
    return EngagementAck(
      xp: serverXp,
      level: 1 + serverXp ~/ 100,
      awarded: dup ? 0 : award,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRecorder recorder;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    recorder = _FakeRecorder();
  });
  tearDown(() => db.close());

  EngagementEventService service() => EngagementEventService(
        db: db,
        recorder: recorder,
        isSyncEnabled: () => true,
        getAuthUserId: () async => 'user-1',
      );

  Future<int> ackXp() async => (await db
          .customSelect('SELECT total_xp FROM xp_levels LIMIT 1;')
          .getSingle())
      .read<int>('total_xp');

  Future<int> countWhere(String where) async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM engagement_events WHERE $where;')
          .getSingle())
      .read<int>('n');

  test('offline event creation records a pending event without an award',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    expect(await countWhere("status='pending'"), 1);
    // No server call happened, aggregate unchanged.
    expect(recorder.calls, 0);
  });

  test('offline progress is visible via projection (acknowledged + pending)',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1'); // 15
    await service().enqueue(eventType: 'bill_payment', eventId: 'e2'); // 5
    final p = await service().projection();
    expect(p.acknowledgedXp, 0);
    expect(p.pendingCount, 2);
    expect(p.projectedXp, 20, reason: 'acknowledged 0 + projected 15 + 5');
    expect(p.hasPending, isTrue);
  });

  test('push submits events, the server awards, and the ack is mirrored locally',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    final synced = await service().push();
    expect(synced, 1);
    expect(recorder.serverXp, 15);
    expect(await ackXp(), 15, reason: 'acknowledged server aggregate stored');
    expect(await countWhere("status='synced'"), 1);
    // Projection now equals acknowledged (nothing pending).
    final p = await service().projection();
    expect(p.projectedXp, 15);
    expect(p.pendingCount, 0);
  });

  test('duplicate event replay awards exactly once (idempotent)', () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    await service().push();
    // Re-enqueue the SAME event id (e.g. from another device / replay) and push.
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    await service().push();
    expect(recorder.serverXp, 15, reason: 'the same event_id is awarded once');
    expect(await ackXp(), 15);
  });

  test('a duplicate business action is dropped before it is even queued',
      () async {
    final s = service();
    await s.enqueue(
        eventType: 'goal_contribution', eventId: 'e1', businessKey: 'goal:42');
    await s.enqueue(
        eventType: 'goal_contribution', eventId: 'e2', businessKey: 'goal:42');
    expect(await countWhere('1=1'), 1, reason: 'same business_key → one event');
  });

  test('response lost after server acceptance: retry is idempotent', () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    // Simulate the server ACCEPTING + recording e1, but the client crashing
    // before it saw the ack — so e1 is still pending locally.
    await recorder.record(
        eventId: 'e1', eventType: 'goal_contribution', occurredAt: 'x');
    expect(recorder.serverXp, 15);
    expect(await countWhere("status='pending'"), 1);
    // The client retries the still-pending event; the server is idempotent, so
    // it does NOT double-award, and the client converges to the acknowledged 15.
    await service().push();
    expect(recorder.serverXp, 15, reason: 'awarded once despite the retry');
    expect(await ackXp(), 15);
    expect(await countWhere("status='synced'"), 1);
  });

  test('the projection removes a pending event exactly once after ack',
      () async {
    await service().enqueue(eventType: 'bill_payment', eventId: 'e1');
    expect((await service().projection()).pendingCount, 1);
    await service().push();
    final p = await service().projection();
    expect(p.pendingCount, 0, reason: 'acknowledged event leaves the projection');
    expect(p.projectedXp, p.acknowledgedXp, reason: 'no double count');
  });

  test('an unknown/malformed event type dead-letters (never awards)', () async {
    await service().enqueue(eventType: 'totally_made_up', eventId: 'e1');
    final synced = await service().push();
    expect(synced, 0);
    expect(await countWhere("status='dead'"), 1);
    expect(recorder.serverXp, 0);
  });

  test('arbitrary XP tampering is impossible — the client submits a TYPE, and '
      'an unknown type is rejected server-side', () async {
    // There is no XP parameter on enqueue/record; the only lever is event_type,
    // and an unrecognised one is rejected (dead-lettered), never awarded.
    await service().enqueue(eventType: 'grant_me_1000000_xp', eventId: 'e1');
    await service().push();
    expect(await ackXp(), 0);
    expect(await countWhere("status='dead'"), 1);
  });

  test('a dead-letter does not block a subsequent valid event; re-arm restores it',
      () async {
    final s = service();
    await s.enqueue(eventType: 'bad_type', eventId: 'bad');
    await s.enqueue(eventType: 'bill_payment', eventId: 'good');
    await s.push();
    expect(await countWhere("status='dead'"), 1);
    expect(await countWhere("status='synced'"), 1, reason: 'valid one still syncs');
    expect(await ackXp(), 5);
    // Re-arm after a compatible upgrade restores the dead event for retry.
    final rearmed = await s.reArmDeadLetter();
    expect(rearmed, 1);
    expect(await countWhere("status='pending'"), 1);
  });

  test('a transient failure keeps the event pending, not dead', () async {
    final s = service();
    await s.enqueue(eventType: 'bill_payment', eventId: 'e1');
    recorder.failWith = const PostgrestException(message: 'net', code: '503');
    await s.push();
    expect(await countWhere("status='pending'"), 1);
    expect(await s.deadLetterCount(), 0);
  });
}
