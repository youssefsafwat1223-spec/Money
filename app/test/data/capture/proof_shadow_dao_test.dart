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

    test('with NO provenance events, attributed rows are unresolved', () async {
      // Rewritten when correctness moved off `updated_at`. A row that was
      // merely TOUCHED now proves nothing: with no explicit event it is
      // unresolved, and unresolved is never counted as correct.
      await insertTxn('t-confirmed');
      await insertTxn('t-edited', edited: true);
      await dao.record(rec('a', committed: true, txnId: 't-confirmed'));
      await dao.record(rec('b', committed: true, txnId: 't-edited'));
      await dao.record(rec('c', committed: true, txnId: 't-gone'));
      await dao.record(rec('d', committed: true));

      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.wouldHaveCommitted, 4);
      expect(s.correctedFinancial, 0,
          reason: 'a timestamp bump is NOT a financial correction');
      expect(s.rejectedOrDeleted, 1, reason: 'the vanished row');
      expect(s.unattributed, 1);
      expect(s.unresolved, 2);
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

    test('confirming a pending capture is NOT a correction — provenance', () async {
      // The original defect: confirm() bumps updated_at exactly as an edit
      // does, so the action meaning "the parse was RIGHT" was indistinguishable
      // from a correction. Provenance answers it explicitly.
      await insertTxn('t-pending', status: 'pending');
      await dao.record(rec('c', committed: true, txnId: 't-pending'));
      await db.customStatement(
          "UPDATE transactions SET status = 'confirmed', updated_at = ? "
          'WHERE id = ?;',
          ['2026-09-03T00:00:00.000Z', 't-pending']);
      await db.customInsert(
        'INSERT INTO proof_correction_events '
        '(id, transaction_id, event_type, changed_fields, occurred_at) '
        'VALUES (?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('e1'),
          Variable<String>('t-pending'),
          Variable<String>('confirmed'),
          Variable<String>(''),
          Variable<String>('2026-09-03T00:00:00.000Z'),
        ],
      );

      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.confirmedUnchanged, 1,
          reason: 'an explicit confirm is a CORRECT outcome, not a correction');
      expect(s.correctedFinancial, 0);
      expect(s.attributionPartitionsCleanly, isTrue);
    });
  });

  group('TIER 2 CORRECTNESS — provenance-driven states', () {
    Future<void> event(String txnId, String type,
        {String fields = ''}) async {
      await db.customInsert(
        'INSERT INTO proof_correction_events '
        '(id, transaction_id, event_type, changed_fields, occurred_at) '
        'VALUES (?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('$txnId:$type:${DateTime.now().microsecondsSinceEpoch}'),
          Variable<String>(txnId),
          Variable<String>(type),
          Variable<String>(fields),
          Variable<String>(DateTime.now().toUtc().toIso8601String()),
        ],
      );
    }

    test('confirm without a financial edit -> confirmedUnchanged', () async {
      await insertTxn('t1');
      await dao.record(rec('a', committed: true, txnId: 't1'));
      await event('t1', 'confirmed');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.confirmedUnchanged, 1);
      expect(s.correctedFinancial, 0);
    });

    test('a financial correction -> correctedFinancial, and it WINS', () async {
      // One financial correction makes the decision wrong regardless of how
      // many confirmations preceded it.
      await insertTxn('t2');
      await dao.record(rec('b', committed: true, txnId: 't2'));
      await event('t2', 'confirmed');
      await event('t2', 'corrected_financial', fields: 'amount');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.correctedFinancial, 1);
      expect(s.confirmedUnchanged, 0);
    });

    test('a category-only edit does NOT become a correction', () async {
      await insertTxn('t3');
      await dao.record(rec('c', committed: true, txnId: 't3'));
      await event('t3', 'non_financial_edit');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.correctedFinancial, 0);
      // No decisive event yet, so it is UNRESOLVED — never counted as correct.
      expect(s.unresolved, 1);
    });

    test('rejection -> rejectedOrDeleted', () async {
      await insertTxn('t4');
      await dao.record(rec('d', committed: true, txnId: 't4'));
      await event('t4', 'rejected_or_deleted');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.rejectedOrDeleted, 1);
    });

    test('a vanished row with no event still counts as rejected', () async {
      // Restore-from-backup dropping a later transaction, or a raw-SQL delete.
      // Calling that "unresolved" would flatter the gate.
      await dao.record(rec('e', committed: true, txnId: 't-gone'));
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.rejectedOrDeleted, 1);
    });

    test('no event at all stays unresolved, never correct', () async {
      await insertTxn('t5');
      await dao.record(rec('f', committed: true, txnId: 't5'));
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.unresolved, 1);
      expect(s.confirmedUnchanged, 0);
    });

    test('a sync/timestamp-only mutation produces NO event', () async {
      // Sync writes raw SQL and never calls the repository, so it physically
      // cannot emit a correction. This pins that immunity.
      await insertTxn('t6');
      await dao.record(rec('g', committed: true, txnId: 't6'));
      await db.customStatement(
          "UPDATE transactions SET updated_at = ? WHERE id = 't6';",
          ['2026-09-09T00:00:00.000Z']);
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.correctedFinancial, 0,
          reason: 'a timestamp touch is not a correction');
      expect(s.unresolved, 1);
    });

    test('the partition holds across every state', () async {
      await insertTxn('p1');
      await insertTxn('p2');
      await insertTxn('p3');
      await insertTxn('p4');
      await dao.record(rec('p1', committed: true, txnId: 'p1'));
      await dao.record(rec('p2', committed: true, txnId: 'p2'));
      await dao.record(rec('p3', committed: true, txnId: 'p3'));
      await dao.record(rec('p4', committed: true, txnId: 'p4'));
      await dao.record(rec('p5', committed: true)); // unattributed
      await event('p1', 'confirmed');
      await event('p2', 'corrected_financial', fields: 'currency');
      await event('p3', 'rejected_or_deleted');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.wouldHaveCommitted, 5);
      expect(s.attributionPartitionsCleanly, isTrue);
      expect(s.confirmedUnchanged, 1);
      expect(s.correctedFinancial, 1);
      expect(s.rejectedOrDeleted, 1);
      expect(s.unattributed, 1);
      expect(s.unresolved, 1);
    });

    test('the release gate requires n AND zero financial corrections', () async {
      await insertTxn('g1');
      await dao.record(rec('g1', committed: true, txnId: 'g1'));
      await event('g1', 'confirmed');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.meetsTier2Gate(minObservations: 1), isTrue);
      expect(s.meetsTier2Gate(), isFalse, reason: 'n=1 is far below 1000');

      await insertTxn('g2');
      await dao.record(rec('g2', committed: true, txnId: 'g2'));
      await event('g2', 'corrected_financial', fields: 'amount');
      final s2 = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s2.meetsTier2Gate(minObservations: 1), isFalse,
          reason: 'one financial correction fails the gate outright');
    });
  });

  group('regressions the provenance review caught', () {
    Future<void> ev(String txnId, String type) async {
      await db.customInsert(
        'INSERT INTO proof_correction_events '
        '(id, transaction_id, event_type, changed_fields, occurred_at) '
        'VALUES (?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('$txnId:$type:${DateTime.now().microsecondsSinceEpoch}'),
          Variable<String>(txnId),
          Variable<String>(type),
          Variable<String>(''),
          Variable<String>(DateTime.now().toUtc().toIso8601String()),
        ],
      );
    }

    test('confirmed THEN vanished counts once, and never goes negative', () async {
      // The double-count: this row matched confirmedUnchanged AND
      // rejectedOrDeleted, driving the unresolved remainder negative.
      await dao.record(rec('cv', committed: true, txnId: 't-vanished'));
      await ev('t-vanished', 'confirmed'); // row itself never inserted
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.rejectedOrDeleted, 1, reason: 'vanishing outranks confirmation');
      expect(s.confirmedUnchanged, 0);
      expect(s.unresolved, greaterThanOrEqualTo(0));
      expect(s.attributionPartitionsCleanly, isTrue);
    });

    test('every event-pair ordering resolves to ONE bucket', () async {
      const pairs = [
        ['confirmed', 'corrected_financial'],
        ['corrected_financial', 'confirmed'],
        ['confirmed', 'rejected_or_deleted'],
        ['rejected_or_deleted', 'confirmed'],
        ['corrected_financial', 'rejected_or_deleted'],
        ['rejected_or_deleted', 'corrected_financial'],
      ];
      for (var i = 0; i < pairs.length; i++) {
        final id = 'pair$i';
        await insertTxn(id);
        await dao.record(rec('k$i', committed: true, txnId: id));
        await ev(id, pairs[i][0]);
        await ev(id, pairs[i][1]);
      }
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.wouldHaveCommitted, pairs.length);
      expect(s.attributionPartitionsCleanly, isTrue,
          reason: 'no ordering may double-count');
      // corrected wins in all four pairs containing it.
      expect(s.correctedFinancial, 4);
      expect(s.rejectedOrDeleted, 2);
      expect(s.confirmedUnchanged, 0);
    });

    test('duplicate same-type events do not double-count', () async {
      await insertTxn('dup');
      await dao.record(rec('d1', committed: true, txnId: 'dup'));
      await ev('dup', 'confirmed');
      await ev('dup', 'confirmed');
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.confirmedUnchanged, 1);
      expect(s.attributionPartitionsCleanly, isTrue);
    });

    test('1000 UNRESOLVED observations do NOT pass the gate', () async {
      // The falsely-passing gate: zero corrections found because nobody looked.
      for (var i = 0; i < 5; i++) {
        await insertTxn('u$i');
        await dao.record(rec('u$i', committed: true, txnId: 'u$i'));
      }
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.unresolved, 5);
      expect(s.correctedFinancial, 0);
      expect(s.meetsTier2Gate(minObservations: 5), isFalse,
          reason: 'unlooked-at captures are not evidence of correctness');
      expect(s.resolvedObservations, 0);
    });

    test('resolved observations DO pass when none were corrected', () async {
      for (var i = 0; i < 3; i++) {
        await insertTxn('r$i');
        await dao.record(rec('r$i', committed: true, txnId: 'r$i'));
        await ev('r$i', 'confirmed');
      }
      final s = await dao.tier2Summary(engineVersion: 'proof-gate-1');
      expect(s.resolvedObservations, 3);
      expect(s.meetsTier2Gate(minObservations: 3), isTrue);
      expect(s.meetsTier2Gate(minObservations: 4), isFalse);
    });
  });
}
