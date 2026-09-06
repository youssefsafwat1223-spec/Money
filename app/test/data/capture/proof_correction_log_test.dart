import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/capture/proof_correction_log.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// What counts as a Proof correctness failure, and — just as important — what
/// does not. `updated_at` could answer neither question.
void main() {
  late AppDatabase db;
  late ProofCorrectionLog log;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    log = ProofCorrectionLog(db);
  });
  tearDown(() async => db.close());

  Future<List<String>> eventsFor(String id) async {
    final rows = await db.customSelect(
      'SELECT event_type AS e FROM proof_correction_events '
      'WHERE transaction_id = ? ORDER BY occurred_at',
      variables: <Variable<Object>>[Variable<String>(id)],
    ).get();
    return [for (final r in rows) r.read<String>('e')];
  }

  group('financialDelta — what counts as a financial correction', () {
    Set<ProofField> delta({
      int oldAmt = 100,
      int newAmt = 100,
      String oldCur = 'SAR',
      String newCur = 'SAR',
      String oldType = 'payment',
      String newType = 'payment',
      String? oldAcc = 'a1',
      String? newAcc = 'a1',
    }) =>
        ProofCorrectionLog.financialDelta(
          oldAmountMinor: oldAmt,
          newAmountMinor: newAmt,
          oldCurrency: oldCur,
          newCurrency: newCur,
          oldType: oldType,
          newType: newType,
          oldAccountId: oldAcc,
          newAccountId: newAcc,
        );

    test('amount change IS financial', () {
      expect(delta(newAmt: 250), {ProofField.amount});
    });
    test('currency change IS financial', () {
      expect(delta(newCur: 'KWD'), {ProofField.currency});
    });
    test('direction/type change IS financial', () {
      expect(delta(newType: 'income'), {ProofField.direction});
    });
    test('account change IS financial (conservative)', () {
      // Proof does not corroborate an account today. Counting it can only make
      // the gate STRICTER, which is the safe direction for a safety metric.
      expect(delta(newAcc: 'a2'), {ProofField.account});
    });
    test('no change at all is EMPTY — re-saving is not a correction', () {
      expect(delta(), isEmpty);
    });
    test('currency comparison ignores case and padding', () {
      expect(delta(oldCur: 'sar', newCur: ' SAR '), isEmpty);
    });
    test('a null on either side of amount is not a change', () {
      // An unknown old value is not evidence the parse was wrong.
      expect(
        ProofCorrectionLog.financialDelta(
          oldAmountMinor: null,
          newAmountMinor: 500,
          oldCurrency: 'SAR',
          newCurrency: 'SAR',
          oldType: 'payment',
          newType: 'payment',
          oldAccountId: 'a1',
          newAccountId: 'a1',
        ),
        isEmpty,
      );
    });
  });

  group('recordEdit picks the event from the delta', () {
    test('a financial delta logs corrected_financial', () async {
      await log.recordEdit(
          transactionId: 't1', changedFields: const {ProofField.amount});
      expect(await eventsFor('t1'), ['corrected_financial']);
    });

    test('an EMPTY delta logs non_financial_edit, never a correction', () async {
      // Category-only, merchant-only, note-only and date-only edits all arrive
      // here with an empty delta.
      await log.recordEdit(transactionId: 't2', changedFields: const {});
      expect(await eventsFor('t2'), ['non_financial_edit']);
    });
  });

  group('the log is append-only and never load-bearing', () {
    test('multiple events for one transaction are all kept', () async {
      await log.record(
          transactionId: 't3', event: ProofCorrectionEvent.confirmed);
      await log.recordEdit(
          transactionId: 't3', changedFields: const {ProofField.currency});
      expect(await eventsFor('t3'), ['confirmed', 'corrected_financial']);
    });

    test('recording NEVER throws, even on a closed database', () async {
      await db.close();
      await expectLater(
        log.record(transactionId: 't4', event: ProofCorrectionEvent.confirmed),
        completes,
      );
    });

    test('no financial VALUES are stored — field classes only', () async {
      await log.recordEdit(
          transactionId: 't5',
          changedFields: const {ProofField.amount, ProofField.currency});
      final rows = await db
          .customSelect('SELECT changed_fields AS c FROM proof_correction_events '
              "WHERE transaction_id = 't5'")
          .get();
      expect(rows.single.read<String>('c'), 'amount,currency');
      // Sorted and class-only: no amount, no currency code, no merchant.
      for (final leak in ['SAR', '250', 'ستاربكس']) {
        expect(rows.single.read<String>('c').contains(leak), isFalse);
      }
    });
  });

  group('system writers can NEVER log a correction', () {
    test('a systemRepair edit records NOTHING', () async {
      // THE blocker this guard exists for. AccountCurrencyRepairService runs at
      // EVERY BOOT and backfills orphaned account_ids THROUGH the repository
      // (it needs outbox enqueueing), so the raw-SQL immunity argument does not
      // cover it. Unguarded it would append a false corrected_financial per row
      // from the first shipped boot — into an append-only log that carries
      // nothing distinguishing repair from user, so the poison would not be
      // separable afterwards.
      await log.recordEdit(
        transactionId: 'sys1',
        changedFields: const {ProofField.account},
        origin: ProofEditOrigin.systemRepair,
      );
      expect(await eventsFor('sys1'), isEmpty);
    });

    test('the same edit from a USER is recorded', () async {
      // Non-vacuity: proves the guard suppresses by ORIGIN, not by accident.
      await log.recordEdit(
        transactionId: 'usr1',
        changedFields: const {ProofField.account},
        origin: ProofEditOrigin.user,
      );
      expect(await eventsFor('usr1'), ['corrected_financial']);
    });

    test('user is the DEFAULT, so a new call site is recorded not dropped', () async {
      // The safe default direction: forgetting to declare origin over-counts
      // corrections (stricter gate), it never hides one.
      await log.recordEdit(
          transactionId: 'def1', changedFields: const {ProofField.amount});
      expect(await eventsFor('def1'), ['corrected_financial']);
    });
  });

  group('every event type survives the CHECK constraint', () {
    test('no enum value is silently rejected by the schema', () async {
      // The table CHECKs event_type, and record() swallows its own errors — so
      // adding a fifth enum value without extending the CHECK would produce a
      // compile-clean, test-passing build that DROPS every such event. This
      // test fails loudly instead.
      for (final e in ProofCorrectionEvent.values) {
        await log.record(transactionId: 'chk_${e.name}', event: e);
        expect(await eventsFor('chk_${e.name}'), hasLength(1),
            reason: '${e.name} was rejected by the CHECK constraint and '
                'silently dropped — extend the CHECK in app_database.dart');
      }
    });
  });
}
