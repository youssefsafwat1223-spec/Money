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
  }) =>
      ProofShadowRecord(
        evaluationKey: key,
        evaluatedAt: DateTime.utc(2026, 9, 5),
        engineVersion: engine,
        gateMode: ProofGateMode.shadow,
        outcome: committed ? ProofGateOutcome.agree : ProofGateOutcome.disagreeVerdict,
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
    final s = await dao.summary(engineVersion: 'proof-gate-1');
    expect(s['evaluations'], 1);
    expect(s['would_have_committed'], 1);
  });

  test('IDEMPOTENCY: the same key twice is ONE observation', () async {
    // Reprocessing must not inflate the Tier 2 denominator and make the
    // false-commit rate look better than it is.
    await dao.record(rec('dup', committed: true));
    await dao.record(rec('dup', committed: true));
    final s = await dao.summary(engineVersion: 'proof-gate-1');
    expect(s['evaluations'], 1);
  });

  test('summary is SCOPED to one engine version', () async {
    // An unscoped count would blend observations produced under different gates
    // and thresholds into one meaningless rate.
    await dao.record(rec('a', committed: true, engine: 'proof-gate-1'));
    await dao.record(rec('b', committed: true, engine: 'proof-gate-2'));
    expect((await dao.summary(engineVersion: 'proof-gate-1'))['evaluations'], 1);
    expect((await dao.summary(engineVersion: 'proof-gate-2'))['evaluations'], 1);
    expect(await dao.engineVersions(), ['proof-gate-1', 'proof-gate-2']);
  });

  test('a successful proposal is NOT counted as a refusal', () async {
    // An absent reason stores as '' rather than NULL; an IS NOT NULL filter
    // alone would count every proposed evaluation as refused.
    await dao.record(rec('ok', committed: true));
    await dao.record(rec('no', refusal: ProofProposalRefusal.amountAmbiguous));
    final s = await dao.summary(engineVersion: 'proof-gate-1');
    expect(s['evaluations'], 2);
    expect(s['refusal_amountAmbiguous'], 1);
    expect(s.keys.where((k) => k.startsWith('refusal_')).length, 1);
  });

  test('recording NEVER throws, even on a closed database', () async {
    // A diagnostic write must not be able to affect a commit.
    await db.close();
    await expectLater(dao.record(rec('after-close')), completes);
  });
}
