/// PHASE 8 — durability of the capture work item.
///
/// The interesting failures are not "does the query work" but "what happens if
/// the process dies HERE". So the tests are organised by crash boundary, and
/// each one asserts the property that boundary is supposed to protect.
///
/// The claim under test is deliberately narrow:
///   · at most one ACCEPTED result — enforced, tested;
///   · no second model call once a result is persisted — enforced, tested;
///   · exactly-once external model execution — NOT claimed, and a test asserts
///     that unavoidable duplicates are counted rather than hidden.
library;

// drift also exports isNull/isNotNull (SQL builders); hide them so the
// matcher versions win in expectations.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/capture_work_item_repository.dart';

/// A minimal database exposing exactly the v32 table, so these tests exercise
/// the repository's real SQL and CAS without opening the full encrypted
/// database (which needs keystore, platform channels and migrations).
class _WorkItemDb extends GeneratedDatabase {
  _WorkItemDb() : super(NativeDatabase.memory());

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 33;

  Future<void> createSchema() => customStatement('''
    CREATE TABLE capture_work_items (
      capture_uuid TEXT PRIMARY KEY,
      content_fingerprint TEXT NULL,
      state TEXT NOT NULL DEFAULT 'received'
        CHECK(state IN ('received','model_in_flight','model_result_persisted',
                        'applied','review','rejected','dead_letter')),
      lease_owner TEXT NULL,
      claimed_at TEXT NULL,
      lease_expires_at TEXT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      model_result_json TEXT NULL,
      model_executions INTEGER NOT NULL DEFAULT 0,
      transaction_id TEXT NULL,
      revision INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );''');
}

void main() {
  late _WorkItemDb db;
  late CaptureWorkItemRepository repo;

  setUp(() async {
    db = _WorkItemDb();
    await db.createSchema();
    repo = CaptureWorkItemRepository(db);
  });

  tearDown(() => db.close());

  group('identity — capture UUID resolves, fingerprint only signals', () {
    test('re-presenting the same capture UUID resolves the existing item', () async {
      final a = await repo.resolveOrCreate(captureUuid: 'u1');
      final b = await repo.resolveOrCreate(captureUuid: 'u1');
      expect(b.captureUuid, a.captureUuid);
      expect(await repo.count(), 1, reason: 'no duplicate work item');
    });

    test('re-presentation does not reset state or clear a result', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{"a":1}', owner: 'w1');

      final again = await repo.resolveOrCreate(captureUuid: 'u1');
      expect(again.state, CaptureWorkState.modelResultPersisted);
      expect(again.modelResultJson, '{"a":1}',
          reason: 'a duplicate delivery must not undo completed work');
    });

    test('identical fingerprints stay SEPARATE work items', () async {
      // Two identical messages are genuinely ambiguous — a person can buy the
      // same coffee twice. The fingerprint may raise a review; it may never
      // merge two captures into one.
      await repo.resolveOrCreate(captureUuid: 'u1', contentFingerprint: 'fp');
      await repo.resolveOrCreate(captureUuid: 'u2', contentFingerprint: 'fp');
      expect(await repo.count(), 2);
      expect((await repo.withFingerprint('fp')).length, 2,
          reason: 'the signal is visible for review, not collapsed');
    });
  });

  group('CRASH between Drift COMMIT and native ACK', () {
    test('the re-presented item finds its row; no duplicate is created', () async {
      // 1-3 happened: row committed. 4 did not: native never got its ACK.
      await repo.resolveOrCreate(captureUuid: 'u1', contentFingerprint: 'fp');
      // …crash… native re-presents the same item on next boot:
      final resolved =
          await repo.resolveOrCreate(captureUuid: 'u1', contentFingerprint: 'fp');
      expect(resolved.state, CaptureWorkState.received);
      expect(await repo.count(), 1);
    });
  });

  group('CRASH while the model was in flight', () {
    test('an expired lease is reclaimable — a dead worker cannot strand it',
        () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      await repo.resolveOrCreate(captureUuid: 'u1', now: past);
      await repo.claim(
          captureUuid: 'u1',
          owner: 'crashed',
          leaseFor: const Duration(minutes: 1),
          now: past);

      final stranded = await repo.reclaimable(DateTime.now());
      expect(stranded.map((e) => e.captureUuid), contains('u1'));

      final reclaimed = await repo.claim(
          captureUuid: 'u1', owner: 'w2', leaseFor: const Duration(minutes: 5));
      expect(reclaimed, isNotNull);
      expect(reclaimed!.leaseOwner, 'w2');
      expect(reclaimed.attemptCount, 2, reason: 'the retry is counted');
    });

    test('a LIVE lease held by another worker is refused', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      final second = await repo.claim(
          captureUuid: 'u1', owner: 'w2', leaseFor: const Duration(minutes: 5));
      expect(second, isNull);
    });

    test('duplicate external execution is COUNTED, not hidden', () async {
      // The provider ran, then we crashed before persisting. That call really
      // happened and its cost was really incurred; a retry will call again.
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.noteModelExecutionWithoutResult('u1'); // lost result

      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{"a":1}', owner: 'w1');

      final item = await repo.find('u1');
      expect(item!.modelExecutions, 2,
          reason: 'exactly-once provider execution is NOT claimed; the real '
              'duplicate rate must be visible');
    });
  });

  group('at most ONE accepted result', () {
    test('a second persist is refused', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      expect(
          await repo.persistModelResult(
              captureUuid: 'u1', resultJson: '{"first":true}', owner: 'w1'),
          isTrue);
      expect(
          await repo.persistModelResult(
              captureUuid: 'u1', resultJson: '{"second":true}', owner: 'w2'),
          isFalse);
      expect((await repo.find('u1'))!.modelResultJson, '{"first":true}',
          reason: 'the first accepted result is final');
    });

    test('no second model call after a result exists — claim is refused', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{"a":1}', owner: 'w1');

      expect(
          await repo.claim(
              captureUuid: 'u1', owner: 'w2', leaseFor: const Duration(minutes: 5)),
          isNull,
          reason: 'a persisted result must be REPLAYED, never regenerated');
      expect(await repo.replayPersistedResult('u1'), '{"a":1}');
    });

    test('a persisted item is not reclaimable even with an expired lease',
        () async {
      final past = DateTime.now().subtract(const Duration(hours: 1));
      await repo.resolveOrCreate(captureUuid: 'u1', now: past);
      await repo.claim(
          captureUuid: 'u1',
          owner: 'w1',
          leaseFor: const Duration(minutes: 1),
          now: past);
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{"a":1}', owner: 'w1', now: past);

      expect(await repo.reclaimable(DateTime.now()), isEmpty,
          reason: 'a stored result outranks an expired lease');
    });
  });

  group('lifecycle', () {
    test('received → in_flight → persisted → applied', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      expect((await repo.find('u1'))!.state, CaptureWorkState.received);
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      expect((await repo.find('u1'))!.state, CaptureWorkState.modelInFlight);
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{}', owner: 'w1');
      expect((await repo.find('u1'))!.state,
          CaptureWorkState.modelResultPersisted);
      await repo.markTerminal(
          captureUuid: 'u1',
          state: CaptureWorkState.applied,
          transactionId: 't1');
      final done = await repo.find('u1');
      expect(done!.state, CaptureWorkState.applied);
      expect(done.transactionId, 't1');
    });

    test('the lease is released on a terminal state', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.markTerminal(
          captureUuid: 'u1', state: CaptureWorkState.rejected);
      final item = await repo.find('u1');
      expect(item!.leaseOwner, isNull);
      expect(item.leaseExpiresAt, isNull);
    });

    test('revision increments monotonically for CAS', () async {
      await repo.resolveOrCreate(captureUuid: 'u1');
      final r0 = (await repo.find('u1'))!.revision;
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      final r1 = (await repo.find('u1'))!.revision;
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{}', owner: 'w1');
      final r2 = (await repo.find('u1'))!.revision;
      expect(r1, greaterThan(r0));
      expect(r2, greaterThan(r1));
    });
  });

  group('privacy — wipe, account delete, consent revocation', () {
    test('deleteAll erases every work item', () async {
      await repo.resolveOrCreate(captureUuid: 'u1', contentFingerprint: 'fp');
      await repo.resolveOrCreate(captureUuid: 'u2');
      await repo.claim(
          captureUuid: 'u1', owner: 'w1', leaseFor: const Duration(minutes: 5));
      await repo.persistModelResult(
          captureUuid: 'u1', resultJson: '{"pii":"x"}', owner: 'w1');

      await repo.deleteAll();
      expect(await repo.count(), 0,
          reason: 'derived model output must not survive a wipe as an orphan '
              'record of a message the user asked to be forgotten');
      expect(await repo.find('u1'), isNull);
    });
  });
}
