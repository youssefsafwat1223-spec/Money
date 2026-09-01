/// PHASE 9A — the real label evidence pipeline.
///
/// Phase 11's precision gate is only as trustworthy as this table. So the tests
/// are weighted toward the ways a label could be WRONG rather than missing: a
/// stale action recording evidence about state the user was not looking at, a
/// replay inflating the count, or bank text leaking into storage that exists
/// for a different purpose.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/capture_review_label_repository.dart';
import 'package:money_companion/domain/capture/capture_review_state.dart';

class _LabelDb extends GeneratedDatabase {
  _LabelDb() : super(NativeDatabase.memory());

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 33;

  Future<void> createSchema() => customStatement('''
    CREATE TABLE capture_review_labels (
      id TEXT PRIMARY KEY,
      capture_uuid TEXT NOT NULL,
      transaction_id TEXT NULL,
      review_state TEXT NOT NULL,
      action TEXT NOT NULL
        CHECK(action IN ('accepted','corrected','dismissed')),
      corrected_fields TEXT NOT NULL DEFAULT '',
      corrected_direction INTEGER NOT NULL DEFAULT 0,
      work_item_revision INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(capture_uuid, work_item_revision)
    );''');
}

void main() {
  late _LabelDb db;
  late CaptureReviewLabelRepository repo;

  setUp(() async {
    db = _LabelDb();
    await db.createSchema();
    repo = CaptureReviewLabelRepository(db);
  });

  tearDown(() => db.close());

  Future<LabelWriteResult> write(
    CaptureReviewOutcome outcome, {
    int at = 5,
    int current = 5,
    String? txId = 't1',
  }) =>
      repo.record(
        outcome: outcome,
        outcomeAtRevision: at,
        currentWorkItemRevision: current,
        transactionId: txId,
      );

  group('the four label kinds', () {
    test('accepted suggestion', () async {
      final r = await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      ));
      expect(r.isRecorded, isTrue);
      final rep = await repo.report();
      expect(rep.accepted, 1);
      expect(rep.corrected, 0);
      expect(rep.directionCorrections, 0);
    });

    test('corrected AMOUNT', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.amountConflict,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.amount},
      ));
      final rep = await repo.report();
      expect(rep.corrected, 1);
      expect(rep.correctionsByField['amount'], 1);
    });

    test('corrected CURRENCY', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.currencyConflict,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.currency},
      ));
      expect((await repo.report()).correctionsByField['currency'], 1);
    });

    test('corrected DIRECTION is counted separately', () async {
      // A wrong direction is a wrong-SIGNED transaction. Its correction rate is
      // the single most important number this pipeline produces.
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.directionAmbiguous,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.direction},
      ));
      final rep = await repo.report();
      expect(rep.directionCorrections, 1);
      expect(rep.correctionsByField['direction'], 1);
    });

    test('category-only correction', () async {
      // The money was right; only the label was wrong. Must not be conflated
      // with a financial-field correction.
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.categoryAmbiguous,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.category},
      ));
      final rep = await repo.report();
      expect(rep.correctionsByField['category'], 1);
      expect(rep.correctionsByField.containsKey('amount'), isFalse);
      expect(rep.directionCorrections, 0);
    });
  });

  group('stale actions cannot manufacture evidence', () {
    test('an action against a superseded revision is REFUSED', () async {
      final r = await write(
        const CaptureReviewOutcome(
          captureUuid: 'u1',
          state: CaptureReviewState.proven,
          action: CaptureReviewAction.accepted,
        ),
        at: 3, // the UI was showing revision 3…
        current: 7, // …but the work item is now at 7
      );
      expect(r.isRecorded, isFalse);
      expect(r.rejection, LabelRejection.staleRevision);
      expect(await repo.count(), 0,
          reason: 'the user answered a question about state that no longer '
              'exists; treating that as evidence would bias the precision '
              'estimate toward looking better than reality');
    });

    test('an action at the CURRENT revision is accepted', () async {
      final r = await write(
        const CaptureReviewOutcome(
          captureUuid: 'u1',
          state: CaptureReviewState.proven,
          action: CaptureReviewAction.accepted,
        ),
        at: 7,
        current: 7,
      );
      expect(r.isRecorded, isTrue);
    });
  });

  group('replay is idempotent', () {
    test('recording the same label twice yields ONE row', () async {
      const o = CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      );
      final first = await write(o);
      final second = await write(o);
      expect(first.isRecorded, isTrue);
      expect(second.wasDuplicate, isTrue);
      expect(await repo.count(), 1,
          reason: 'a double tap must not inflate the evidence count');
    });

    test('a LATER revision on the same capture is a separate label', () async {
      const o = CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      );
      await write(o, at: 5, current: 5);
      await write(o, at: 6, current: 6);
      expect(await repo.count(), 2,
          reason: 'the user acted twice, on two genuinely different states');
    });
  });

  group('user edit precedence', () {
    test('a label recorded before a user edit does not overwrite the later one',
        () async {
      // Accept at revision 5, then the user corrects at 6. Both are real
      // actions and both are kept; the later one is not lost to the earlier.
      await write(
        const CaptureReviewOutcome(
          captureUuid: 'u1',
          state: CaptureReviewState.proven,
          action: CaptureReviewAction.accepted,
        ),
        at: 5,
        current: 5,
      );
      await write(
        const CaptureReviewOutcome(
          captureUuid: 'u1',
          state: CaptureReviewState.proven,
          action: CaptureReviewAction.corrected,
          correctedFields: {CorrectedField.amount},
        ),
        at: 6,
        current: 6,
      );
      final labels = await repo.forCapture('u1');
      expect(labels.length, 2);
      expect(labels.last['action'], 'corrected',
          reason: 'the newest user action is preserved in order');
    });
  });

  group('no raw SMS leaks into label storage', () {
    test('the schema has no column capable of holding a message', () async {
      final cols = await db
          .customSelect("PRAGMA table_info('capture_review_labels');")
          .get();
      final names = cols.map((c) => c.read<String>('name')).toSet();
      expect(names, {
        'id',
        'capture_uuid',
        'transaction_id',
        'review_state',
        'action',
        'corrected_fields',
        'corrected_direction',
        'work_item_revision',
        'created_at',
      });
      for (final forbidden in const ['sms', 'body', 'text', 'message', 'raw']) {
        expect(names.any((n) => n.contains(forbidden)), isFalse,
            reason: 'no column may carry bank text: "$forbidden"');
      }
    });

    test('stored values contain no message content', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.amountConflict,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.amount},
      ));
      final row = (await repo.forCapture('u1')).single;
      row.forEach((key, v) {
        final s = v?.toString() ?? '';
        expect(s.contains('ر.س'), isFalse, reason: key);
        expect(s.contains('شراء'), isFalse, reason: key);
        // `created_at` is an ISO timestamp and legitimately contains
        // digit.digit (the fractional seconds); it is not an amount.
        if (key == 'created_at') return;
        expect(RegExp(r'\d+\.\d{2}').hasMatch(s), isFalse,
            reason: 'no amount-shaped value may be stored in "\$key": \$s');
      });
    });
  });

  group('privacy — wipe and per-capture deletion', () {
    test('deleteAll removes every label', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      ));
      await write(
        const CaptureReviewOutcome(
          captureUuid: 'u2',
          state: CaptureReviewState.proven,
          action: CaptureReviewAction.accepted,
        ),
      );
      await repo.deleteAll();
      expect(await repo.count(), 0);
    });

    test('deleting one capture removes only its labels', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      ));
      await write(const CaptureReviewOutcome(
        captureUuid: 'u2',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      ));
      await repo.deleteForCapture('u1');
      expect(await repo.count(), 1);
      expect(await repo.forCapture('u1'), isEmpty);
    });
  });

  group('the precision report states its own limits', () {
    test('an empty report claims no rate rather than 0%', () async {
      final rep = await repo.report();
      expect(rep.total, 0);
      expect(rep.acceptanceRateAmongLabelled, isNull,
          reason: 'no labels means no estimate — not a perfect or a zero one');
    });

    test('the export carries the caveat with the number', () async {
      await write(const CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      ));
      final json = (await repo.report()).toJson();
      expect(json['acceptance_rate_among_labelled'], 1.0);
      expect(json['CAVEAT'], contains('labelled captures only'),
          reason: 'the number must not be readable as system-wide precision');
    });
  });
}
