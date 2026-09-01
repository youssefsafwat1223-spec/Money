/// PHASE 9A — persistence for genuine user labels.
///
/// ## Why this exists at all
///
/// Phase 11 needs an auto-commit PRECISION estimate. Shadow telemetry cannot
/// produce one: without labels, disagreement is not ground truth, and confirmed
/// transactions frequently receive no user action, so the sample is
/// selection-biased. This is the only place real accept/correct evidence is
/// recorded.
///
/// ## What must never be inferred
///
/// A label is an OBSERVATION OF A REAL USER ACTION. These are all forbidden as
/// substitutes, and each is tempting:
///
///   · absence of a correction is not an acceptance — most people never open
///     the transaction at all;
///   · model self-agreement is not correctness;
///   · a shadow disagreement rate is not a precision estimate;
///   · `status == confirmed` alone is not a label — it can be set by sync, by
///     import, or by a default.
///
/// Nothing in this file creates a label from any of those. [record] is called
/// only from a user-initiated review action.
///
/// ## No raw SMS
///
/// There is no column for the message and no parameter that accepts one. A
/// label says "the user corrected the direction on capture X at revision N",
/// which is the entire evidentiary value; storing the bank text alongside would
/// create a second permanent copy for a purpose that does not need it.
library;

import 'package:drift/drift.dart';

import '../../domain/capture/capture_review_state.dart';

/// Why a label was refused. Recording nothing silently would be worse than
/// refusing loudly: the precision gate would then be measuring a sample with
/// unexplained holes in it.
enum LabelRejection {
  /// The UI acted on state that has since moved. Recording this would attach
  /// evidence to a revision the user was no longer actually looking at.
  staleRevision,

  /// A label already exists for this (capture, revision). Replay is expected
  /// and is a no-op, not an error.
  duplicate,
}

class LabelWriteResult {
  const LabelWriteResult.recorded()
      : rejection = null,
        wasDuplicate = false;
  const LabelWriteResult.duplicate()
      : rejection = LabelRejection.duplicate,
        wasDuplicate = true;
  const LabelWriteResult.stale()
      : rejection = LabelRejection.staleRevision,
        wasDuplicate = false;

  final LabelRejection? rejection;
  final bool wasDuplicate;

  bool get isRecorded => rejection == null;
}

/// Aggregate evidence for the Phase-11 precision gate.
class LabelReport {
  const LabelReport({
    required this.total,
    required this.accepted,
    required this.corrected,
    required this.dismissed,
    required this.directionCorrections,
    required this.correctionsByField,
    required this.byReviewState,
  });

  final int total;
  final int accepted;
  final int corrected;
  final int dismissed;
  final int directionCorrections;
  final Map<String, int> correctionsByField;
  final Map<String, int> byReviewState;

  /// Of the labelled outcomes, the fraction the user accepted unchanged.
  ///
  /// This is an ESTIMATE OVER LABELLED CAPTURES ONLY, not over all captures.
  /// Reporting it as system-wide precision would repeat exactly the mistake
  /// this pipeline exists to avoid — captures nobody reviewed are not evidence
  /// of anything.
  double? get acceptanceRateAmongLabelled =>
      total == 0 ? null : accepted / total;

  Map<String, Object?> toJson() => {
        'total_labels': total,
        'accepted': accepted,
        'corrected': corrected,
        'dismissed': dismissed,
        'direction_corrections': directionCorrections,
        'corrections_by_field': correctionsByField,
        'by_review_state': byReviewState,
        'acceptance_rate_among_labelled': acceptanceRateAmongLabelled,
        'CAVEAT': 'labelled captures only — NOT system-wide precision, and not '
            'a substitute for the Phase-7 live measurement',
      };
}

class CaptureReviewLabelRepository {
  CaptureReviewLabelRepository(this._db);

  final GeneratedDatabase _db;

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  /// Record one real user action.
  ///
  /// [currentWorkItemRevision] is the revision the work item holds RIGHT NOW.
  /// [outcomeAtRevision] is the revision the UI was showing. If the world moved
  /// on in between, the label is refused: the user answered a question about
  /// state that no longer exists, and treating that as evidence would poison
  /// the precision estimate in the direction of looking better than reality.
  Future<LabelWriteResult> record({
    required CaptureReviewOutcome outcome,
    required int outcomeAtRevision,
    required int currentWorkItemRevision,
    String? transactionId,
    DateTime? now,
  }) async {
    if (outcomeAtRevision < currentWorkItemRevision) {
      return const LabelWriteResult.stale();
    }

    final fields = (outcome.correctedFields.map((f) => f.name).toList()..sort())
        .join(',');
    final ts = _iso(now ?? DateTime.now());
    // INSERT OR IGNORE against the UNIQUE(capture_uuid, work_item_revision)
    // constraint: a replay writes nothing and is reported as a duplicate.
    await _db.customStatement(
      'INSERT OR IGNORE INTO capture_review_labels '
      '(id, capture_uuid, transaction_id, review_state, action, '
      'corrected_fields, corrected_direction, work_item_revision, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        '${outcome.captureUuid}:$outcomeAtRevision',
        outcome.captureUuid,
        transactionId,
        outcome.state.name,
        outcome.action.name,
        fields,
        outcome.correctedDirection ? 1 : 0,
        outcomeAtRevision,
        ts,
      ],
    );

    final rows = await _db.customSelect(
      'SELECT created_at FROM capture_review_labels '
      'WHERE capture_uuid = ? AND work_item_revision = ?;',
      variables: [
        Variable<String>(outcome.captureUuid),
        Variable<int>(outcomeAtRevision),
      ],
    ).get();
    if (rows.isEmpty) return const LabelWriteResult.stale();
    return rows.first.read<String>('created_at') == ts
        ? const LabelWriteResult.recorded()
        : const LabelWriteResult.duplicate();
  }

  Future<int> count() async {
    final rows = await _db
        .customSelect('SELECT COUNT(*) AS c FROM capture_review_labels;')
        .get();
    return rows.first.read<int>('c');
  }

  Future<List<Map<String, Object?>>> forCapture(String captureUuid) async {
    final rows = await _db.customSelect(
      'SELECT * FROM capture_review_labels WHERE capture_uuid = ? '
      'ORDER BY work_item_revision;',
      variables: [Variable<String>(captureUuid)],
    ).get();
    return rows.map((r) => r.data).toList();
  }

  /// The export/query path the Phase-11 precision gate reads.
  Future<LabelReport> report() async {
    final rows =
        await _db.customSelect('SELECT * FROM capture_review_labels;').get();
    var accepted = 0, corrected = 0, dismissed = 0, direction = 0;
    final byField = <String, int>{};
    final byState = <String, int>{};

    for (final r in rows) {
      switch (r.read<String>('action')) {
        case 'accepted':
          accepted++;
        case 'corrected':
          corrected++;
        case 'dismissed':
          dismissed++;
      }
      if (r.read<int>('corrected_direction') == 1) direction++;
      final state = r.read<String>('review_state');
      byState[state] = (byState[state] ?? 0) + 1;
      final f = r.read<String>('corrected_fields');
      if (f.isNotEmpty) {
        for (final name in f.split(',')) {
          byField[name] = (byField[name] ?? 0) + 1;
        }
      }
    }
    return LabelReport(
      total: rows.length,
      accepted: accepted,
      corrected: corrected,
      dismissed: dismissed,
      directionCorrections: direction,
      correctionsByField: byField,
      byReviewState: byState,
    );
  }

  /// Wipe / account delete / consent revocation. Labels are derived from a
  /// user's captures and are erased with the rest of their data.
  Future<int> deleteAll() =>
      _db.customUpdate('DELETE FROM capture_review_labels;');

  Future<int> deleteForCapture(String captureUuid) => _db.customUpdate(
        'DELETE FROM capture_review_labels WHERE capture_uuid = ?;',
        variables: [Variable<String>(captureUuid)],
      );
}
