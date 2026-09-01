// COUPONS Phase 4 — the local savings ledger, against a REAL database.
//
// The ledger's job is to be defensible. Every test here is about a way a
// savings total could become a number the app cannot stand behind.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/savings_math.dart';
import 'package:money_companion/features/coupons/savings_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SavingsOutcome _saved(int minor, String currency, SavingsEvidence evidence) =>
    SavingsOutcome.saved(amountMinor: minor, currency: currency, evidence: evidence);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late SavingsRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    await db.initialize();
    repo = SavingsRepository(db);
  });
  tearDown(() => db.close());

  test('an abstention writes NOTHING, not a zero', () async {
    // Zero reads as "you saved nothing", which is a different and false
    // statement from "we could not work out what you saved".
    final id = await repo.record(
      const SavingsOutcome.abstained(SavingsAbstention.noStructuredBenefit),
      couponId: 'c-1',
    );
    expect(id, isNull);
    expect(await repo.history(), isEmpty);
    expect((await repo.totals()).isEmpty, isTrue);
  });

  test('currencies are never added together', () async {
    // There is no FX design; a combined figure would be in no currency at all.
    await repo.record(_saved(1000, 'SAR', SavingsEvidence.userConfirmed), couponId: 'c-1');
    await repo.record(_saved(2000, 'EGP', SavingsEvidence.userConfirmed), couponId: 'c-2');
    final totals = await repo.totals();
    expect(totals.totalFor('SAR'), 1000);
    expect(totals.totalFor('EGP'), 2000);
    expect(totals.byCurrencyAndEvidence.keys.toSet(), {'SAR', 'EGP'});
  });

  test('evidence kinds stay separable', () async {
    // "You saved 400" built from guesses and confirmations is a claim the app
    // cannot defend. The breakdown has to survive to the UI.
    await repo.record(_saved(1000, 'SAR', SavingsEvidence.userConfirmed), couponId: 'c-1');
    await repo.record(_saved(500, 'SAR', SavingsEvidence.conversionEstimated), couponId: 'c-2');
    await repo.record(_saved(300, 'SAR', SavingsEvidence.conversionVerified), couponId: 'c-3');

    final totals = await repo.totals();
    expect(totals.byCurrencyAndEvidence['SAR']!.length, 3);
    expect(totals.totalFor('SAR'), 1800);
    // The number the app can defend without qualification.
    expect(totals.verifiedFor('SAR'), 300);
  });

  test('a clawback reverses rather than deletes', () async {
    // A user who saw "you saved 50" and later sees it simply gone experiences
    // the app losing data, which damages trust more than the reversal does.
    await repo.record(_saved(5000, 'SAR', SavingsEvidence.conversionVerified),
        couponId: 'c-1', clickId: 'click-1');
    expect((await repo.totals()).totalFor('SAR'), 5000);

    await repo.reverseForClick('click-1');
    expect((await repo.totals()).totalFor('SAR'), 0);
    expect(await repo.history(), isEmpty, reason: 'reversed entries leave the active view');

    final rows = await db
        .customSelect("SELECT state FROM local_offer_savings WHERE click_id='click-1';")
        .get();
    expect(rows.single.read<String>('state'), 'reversed',
        reason: 'the row survives, marked');
  });

  test('an unknown evidence kind is excluded from totals, not bucketed', () async {
    // Written by a newer build, or corrupted. A figure is only defensible if we
    // know what every part of it means.
    await db.customInsert(
      "INSERT INTO local_offer_savings(id, coupon_id, evidence_kind, amount_minor, "
      "currency, state, occurred_at, created_at) "
      "VALUES ('x','c','from_the_future',9999,'SAR','active','2026-01-01','2026-01-01');",
    );
    expect((await repo.totals()).totalFor('SAR'), 0);
  });

  test('the ledger has no upload path', () async {
    // A server-side savings total would be a spending profile. The repository
    // exposes record / reverse / history / totals and nothing that ships.
    final source = await File(
      'lib/features/coupons/savings_repository.dart',
    ).readAsString();
    for (final forbidden in ['functions.invoke', '.rpc(', 'http.post', 'supabase']) {
      expect(source.toLowerCase().contains(forbidden.toLowerCase()), isFalse,
          reason: 'the savings ledger must never reach the network ($forbidden)');
    }
  });
}
