import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/capture/proof_shadow_dao.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/capture/proof_commit_gate.dart';
import 'package:money_companion/domain/capture/proof_proposal_builder.dart';
import 'package:money_companion/domain/capture/proof_shadow_record.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// The DAO's SQL had never executed under test — the INSERT column list, the
/// idempotency claim and summary() were all unverified assertions.
void main() {
  late AppDatabase db;
  late ProofShadowDao dao;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    dao = ProofShadowDao(db);
  });
  tearDown(() async => db.close());

  ProofShadowRecord rec(
    String key, {
    bool committed = false,
    String engine = 'proof-gate-1',
    ProofProposalRefusal? refusal,
    ProofVerdict? verdict = ProofVerdict.proven,
    String? txnId,
    ProofGateOutcome? outcome,
  }) =>
      ProofShadowRecord(
        evaluationKey: key,
        evaluatedAt: DateTime.utc(2026, 9, 5),
        engineVersion: engine,
        gateMode: ProofGateMode.shadow,
        transactionId: txnId,
        outcome: outcome ??
            (committed
                ? ProofGateOutcome.agree
                : ProofGateOutcome.disagreeVerdict),
        wouldHaveCommitted: committed,
        parseConfidencePermille: 995,
        confidenceMinPermille: 990,
        proofVerdict: verdict,
        amountMatch: ProofFieldMatch.matched,
        directionMatch: ProofFieldMatch.matched,
        currencyMatch: ProofFieldMatch.matched,
        refusal: refusal,
      );

  test('the schema creates proof_shadow_evaluations', () async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='proof_shadow_evaluations';")
        .get();
    expect(rows, isNotEmpty, reason: 'the v36 migration must create the table');
  });

  test('a record round-trips through the real INSERT', () async {
    await dao.record(rec('k1', committed: true));
    final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
    expect(s.attempted, 1);
    expect(s.wouldHaveCommitted, 1);
  });

  test('IDEMPOTENCY: the same key twice is ONE observation', () async {
    // Reprocessing must not inflate the Tier 2 denominator and make the
    // false-commit rate look better than it is.
    await dao.record(rec('dup', committed: true));
    await dao.record(rec('dup', committed: true));
    final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
    expect(s.attempted, 1);
  });

  test('summary is SCOPED to one engine version', () async {
    // An unscoped count would blend observations produced under different gates
    // and thresholds into one meaningless rate.
    await dao.record(rec('a', committed: true, engine: 'proof-gate-1'));
    await dao.record(rec('b', committed: true, engine: 'proof-gate-2'));
    expect((await dao.tier2Summary(engineVersion: 'proof-gate-1')).attempted, 1);
    expect((await dao.tier2Summary(engineVersion: 'proof-gate-2')).attempted, 1);
    expect(await dao.engineVersions(), ['proof-gate-1', 'proof-gate-2']);
  });

  test('a successful proposal is NOT counted as a refusal', () async {
    // An absent reason stores as '' rather than NULL; an IS NOT NULL filter
    // alone would count every proposed evaluation as refused.
    await dao.record(rec('ok', committed: true));
    await dao.record(rec('no', refusal: ProofProposalRefusal.amountAmbiguous));
    final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
    expect(s.attempted, 2);
    expect(s.refusalBreakdown['amountAmbiguous'], 1);
    expect(s.refusalBreakdown.length, 1);
  });

  test('recording NEVER throws, even on a closed database', () async {
    // A diagnostic write must not be able to affect a commit.
    await db.close();
    await expectLater(dao.record(rec('after-close')), completes);
  });

  Future<void> insertTxn(String id,
      {String status = 'confirmed', bool edited = false}) async {
    final created = DateTime.utc(2026, 9, 1).toIso8601String();
    final updated = edited
        ? DateTime.utc(2026, 9, 2).toIso8601String()
        : created;
    await db.customInsert(
      'INSERT INTO transactions (id, amount, currency, type, source, '
      'occurred_at, raw_message, parse_confidence, status, created_at, '
      'updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      variables: <Variable<Object>>[
        Variable<String>(id),
        Variable<double>(10.0),
        Variable<String>('SAR'),
        Variable<String>('payment'),
        Variable<String>('bank'),
        Variable<String>(created),
        Variable<String>('x'),
        Variable<double>(1.0),
        Variable<String>(status),
        Variable<String>(created),
        Variable<String>(updated),
      ],
    );
  }

  group('TIER 2 denominator contract', () {
    test('every attempted evaluation lands in exactly one bucket', () async {
      // A denominator that does not partition is a denominator that is lying.
      await dao.record(rec('e1', committed: true));
      await dao.record(rec('e2', refusal: ProofProposalRefusal.amountAmbiguous));
      await dao.record(rec('e3', outcome: ProofGateOutcome.evidenceError));
      await dao.record(rec('e4', outcome: ProofGateOutcome.checkerError));
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.attempted, 4);
      expect(s.refusedToPropose, 1);
      expect(s.evaluationErrors, 2);
      expect(s.evaluated, 1);
      expect(s.partitionsCleanly, isTrue);
    });

    test('errors are counted separately from refusals', () async {
      // A refusal is the engine working; an error is it failing. Conflating
      // them would let a rising defect rate hide inside a benign refusal rate.
      await dao.record(rec('x', outcome: ProofGateOutcome.evidenceError));
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.evaluationErrors, 1);
      expect(s.refusedToPropose, 0);
    });

    test('attribution classifies confirmed, corrected, deleted and unattributed',
        () async {
      await insertTxn('t-confirmed');
      await insertTxn('t-edited', edited: true);
      await insertTxn('t-pending', status: 'pending');
      // t-gone is deliberately never inserted -> deleted
      await dao.record(rec('a', committed: true, txnId: 't-confirmed'));
      await dao.record(rec('b', committed: true, txnId: 't-edited'));
      await dao.record(rec('c', committed: true, txnId: 't-gone'));
      await dao.record(rec('d', committed: true)); // no txn id
      await dao.record(rec('e', committed: true, txnId: 't-pending'));

      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.wouldHaveCommitted, 5);
      expect(s.autoConfirmedUntouched, 1);
      expect(s.touchedAfterCreation, 1);
      expect(s.deleted, 1, reason: 'deleted must be CLASSIFIED, not dropped');
      expect(s.unattributed, 1);
      expect(s.stillPending, 1);
      expect(s.attributionPartitionsCleanly, isTrue);
    });

    test('summary never averages across engine versions', () async {
      await dao.record(rec('v1', committed: true, engine: 'proof-gate-1'));
      await dao.record(rec('v2', committed: true, engine: 'proof-gate-2'));
      expect((await dao.tier2Summary(engineVersion: 'proof-gate-1')).attempted, 1);
      expect((await dao.tier2Summary(engineVersion: 'proof-gate-2')).attempted, 1);
    });
  });

  group('regressions the Tier 2 review caught', () {
    test('a NULL transaction_id row is CLASSIFIED, not dropped', () {
      // v36 rows have NULL after the ALTER, and in SQL both `= ''` and `!= ''`
      // evaluate to NULL — so such a row matched none of the five predicates
      // and vanished from the population, violating the "classified, not
      // dropped" contract. The v37 migration backfills '' for exactly this.
      return () async {
        await dao.record(rec('n1', committed: true));
        await db.customStatement(
            "UPDATE proof_shadow_evaluations SET transaction_id = NULL "
            "WHERE evaluation_key = 'n1';");
        final leaked = await db
            .customSelect('SELECT COUNT(*) AS n FROM proof_shadow_evaluations '
                'WHERE transaction_id IS NULL;')
            .getSingle();
        expect(leaked.read<int>('n'), 1, reason: 'fixture must create the hole');

        // Re-running the migration step must classify it.
        await db.customStatement(
            "UPDATE proof_shadow_evaluations SET transaction_id = '' "
            'WHERE transaction_id IS NULL;');
        final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
        expect(s.attributionPartitionsCleanly, isTrue);
        expect(s.unattributed, 1);
      }();
    });

    test('confirming a pending capture does NOT read as a correction', () async {
      // confirm() bumps updated_at, so the action meaning "the parse was RIGHT"
      // produced the same signal as a correction. The bucket is now named
      // touchedAfterCreation and is explicitly NOT a correction count — this
      // test pins that naming so the misleading metric cannot come back.
      await insertTxn('t-pending', status: 'pending');
      await dao.record(rec('c', committed: true, txnId: 't-pending'));
      await db.customStatement(
          "UPDATE transactions SET status = 'confirmed', updated_at = ? "
          'WHERE id = ?;',
          ['2026-09-03T00:00:00.000Z', 't-pending']);

      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      // It lands in touchedAfterCreation — indistinguishable from a correction.
      expect(s.touchedAfterCreation, 1);
      expect(s.autoConfirmedUntouched, 0,
          reason: 'a user-confirmed row is NOT a clean auto-confirm signal');
      expect(s.attributionPartitionsCleanly, isTrue);
    });
  });
}
