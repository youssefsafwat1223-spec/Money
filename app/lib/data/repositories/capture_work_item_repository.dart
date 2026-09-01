/// PHASE 8 — the durable capture work item.
///
/// ## The two identity layers, and why conflating them would be a bug
///
/// **`captureUuid` is identity.** Minted once by the native capture layer, it
/// is what a lease, a retry and an ACK all refer to. Resolving by it is what
/// makes re-presentation safe.
///
/// **`contentFingerprint` is a duplicate SIGNAL.** Two byte-identical bank
/// messages are genuinely ambiguous — a person really can buy the same coffee
/// for the same amount at the same shop twice in a minute. So a fingerprint
/// match may raise a review; it may never be taken as proof that two messages
/// are one transaction. Nothing here keys off it, and the column is not unique.
///
/// ## Ordering contract
///
///   1. the native item stays leased/unacked
///   2. [resolveOrCreate] by `captureUuid`
///   3. Drift COMMITs
///   4. only then does the caller ACK native
///
/// A crash between 3 and 4 re-presents the item; step 2 finds the existing row.
/// A crash before 3 loses the row but not the native item. The dangerous
/// ordering — ACK before commit — is what this exists to prevent, and
/// [CaptureWorkItemRepository] cannot ACK anything: it has no native handle.
///
/// ## What is NOT claimed
///
/// **Exactly-once Gemini execution is impossible** and is not claimed. A crash
/// after the provider ran but before the result was persisted leaves no record
/// that it ran; the retry will call again. What IS guaranteed:
///
///   · **at most one ACCEPTED result** — enforced by CAS on `state`;
///   · **no second model call once a result is persisted** — a persisted
///     result is replayed, never regenerated;
///   · unavoidable duplicate external executions are COUNTED
///     (`modelExecutions`) rather than hidden, so the real rate is visible.
library;

import 'package:drift/drift.dart';


/// The backend model-request lifecycle.
enum CaptureWorkState {
  received,
  modelInFlight,
  modelResultPersisted,
  applied,
  review,
  rejected,
  deadLetter;

  String get wire => switch (this) {
        CaptureWorkState.received => 'received',
        CaptureWorkState.modelInFlight => 'model_in_flight',
        CaptureWorkState.modelResultPersisted => 'model_result_persisted',
        CaptureWorkState.applied => 'applied',
        CaptureWorkState.review => 'review',
        CaptureWorkState.rejected => 'rejected',
        CaptureWorkState.deadLetter => 'dead_letter',
      };

  static CaptureWorkState fromWire(String w) => switch (w) {
        'received' => CaptureWorkState.received,
        'model_in_flight' => CaptureWorkState.modelInFlight,
        'model_result_persisted' => CaptureWorkState.modelResultPersisted,
        'applied' => CaptureWorkState.applied,
        'review' => CaptureWorkState.review,
        'rejected' => CaptureWorkState.rejected,
        _ => CaptureWorkState.deadLetter,
      };
}

class CaptureWorkItem {
  const CaptureWorkItem({
    required this.captureUuid,
    required this.state,
    required this.attemptCount,
    required this.modelExecutions,
    required this.revision,
    this.contentFingerprint,
    this.leaseOwner,
    this.claimedAt,
    this.leaseExpiresAt,
    this.modelResultJson,
    this.transactionId,
    this.lastError,
  });

  final String captureUuid;
  final CaptureWorkState state;
  final int attemptCount;

  /// How many times an external model was actually invoked for this item.
  /// Counts unavoidable duplicates rather than pretending they cannot happen.
  final int modelExecutions;

  final int revision;
  final String? contentFingerprint;
  final String? leaseOwner;
  final DateTime? claimedAt;
  final DateTime? leaseExpiresAt;
  final String? modelResultJson;
  final String? transactionId;
  final String? lastError;

  bool get hasPersistedResult =>
      modelResultJson != null &&
      (state == CaptureWorkState.modelResultPersisted ||
          state == CaptureWorkState.applied ||
          state == CaptureWorkState.review);

  bool leaseIsExpired(DateTime now) =>
      leaseExpiresAt != null && now.isAfter(leaseExpiresAt!);
}

class CaptureWorkItemRepository {
  CaptureWorkItemRepository(this._db);

  /// Typed as [GeneratedDatabase] rather than the concrete `AppDatabase`
  /// because this repository only needs the query API. That keeps the
  /// durability contract testable against a minimal in-memory schema instead of
  /// requiring the keystore, platform channels and full migration pipeline —
  /// crash-boundary tests should exercise the SQL, not the app bootstrap.
  final GeneratedDatabase _db;

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  CaptureWorkItem _map(QueryRow r) => CaptureWorkItem(
        captureUuid: r.read<String>('capture_uuid'),
        state: CaptureWorkState.fromWire(r.read<String>('state')),
        attemptCount: r.read<int>('attempt_count'),
        modelExecutions: r.read<int>('model_executions'),
        revision: r.read<int>('revision'),
        contentFingerprint: r.readNullable<String>('content_fingerprint'),
        leaseOwner: r.readNullable<String>('lease_owner'),
        claimedAt: DateTime.tryParse(r.readNullable<String>('claimed_at') ?? ''),
        leaseExpiresAt:
            DateTime.tryParse(r.readNullable<String>('lease_expires_at') ?? ''),
        modelResultJson: r.readNullable<String>('model_result_json'),
        transactionId: r.readNullable<String>('transaction_id'),
        lastError: r.readNullable<String>('last_error'),
      );

  Future<CaptureWorkItem?> find(String captureUuid) async {
    final rows = await _db.customSelect(
      'SELECT * FROM capture_work_items WHERE capture_uuid = ?;',
      variables: [Variable<String>(captureUuid)],
    ).get();
    return rows.isEmpty ? null : _map(rows.first);
  }

  /// STEP 2 of the ordering contract. Idempotent by `captureUuid`.
  ///
  /// Re-presentation of the same native item resolves the EXISTING row and
  /// returns it unchanged. It does not reset state, does not clear a persisted
  /// result and does not bump an attempt — all of which would turn a duplicate
  /// delivery into duplicate work.
  Future<CaptureWorkItem> resolveOrCreate({
    required String captureUuid,
    String? contentFingerprint,
    DateTime? now,
  }) async {
    final existing = await find(captureUuid);
    if (existing != null) return existing;

    final ts = _iso(now ?? DateTime.now());
    // INSERT OR IGNORE, not INSERT: two threads racing the same re-presented
    // item must not make one of them throw.
    await _db.customStatement(
      'INSERT OR IGNORE INTO capture_work_items '
      '(capture_uuid, content_fingerprint, state, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?);',
      [captureUuid, contentFingerprint, CaptureWorkState.received.wire, ts, ts],
    );
    return (await find(captureUuid))!;
  }

  /// Claim a lease. Succeeds only from a claimable state with no live lease.
  ///
  /// An EXPIRED lease is reclaimable — that is the whole point of an expiry;
  /// otherwise a crashed worker would strand the item forever. A LIVE lease
  /// held by someone else is refused.
  Future<CaptureWorkItem?> claim({
    required String captureUuid,
    required String owner,
    required Duration leaseFor,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final item = await find(captureUuid);
    if (item == null) return null;

    // A persisted result is terminal for claiming: replay it, never re-run it.
    if (item.hasPersistedResult) return null;
    if (item.state == CaptureWorkState.rejected ||
        item.state == CaptureWorkState.applied ||
        item.state == CaptureWorkState.deadLetter) {
      return null;
    }
    final leaseLive = item.leaseOwner != null && !item.leaseIsExpired(t);
    if (leaseLive && item.leaseOwner != owner) return null;

    // CAS on revision: two workers reading the same row cannot both claim.
    final updated = await _db.customUpdate(
      'UPDATE capture_work_items SET lease_owner = ?, claimed_at = ?, '
      'lease_expires_at = ?, state = ?, attempt_count = attempt_count + 1, '
      'revision = revision + 1, updated_at = ? '
      'WHERE capture_uuid = ? AND revision = ?;',
      variables: [
        Variable<String>(owner),
        Variable<String>(_iso(t)),
        Variable<String>(_iso(t.add(leaseFor))),
        Variable<String>(CaptureWorkState.modelInFlight.wire),
        Variable<String>(_iso(t)),
        Variable<String>(captureUuid),
        Variable<int>(item.revision),
      ],
    );
    if (updated == 0) return null; // lost the race
    return find(captureUuid);
  }

  /// Persist a model result. **At most one may ever be accepted.**
  ///
  /// Returns false when a result already exists — the caller must then replay
  /// the stored one rather than overwrite it. This is the CAS that makes "at
  /// most one accepted result" a property of the database rather than of
  /// caller discipline.
  Future<bool> persistModelResult({
    required String captureUuid,
    required String resultJson,
    required String owner,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final item = await find(captureUuid);
    if (item == null) return false;
    if (item.hasPersistedResult) return false; // already accepted one

    final updated = await _db.customUpdate(
      'UPDATE capture_work_items SET model_result_json = ?, state = ?, '
      'model_executions = model_executions + 1, lease_owner = NULL, '
      'lease_expires_at = NULL, revision = revision + 1, updated_at = ? '
      'WHERE capture_uuid = ? AND revision = ? AND model_result_json IS NULL;',
      variables: [
        Variable<String>(resultJson),
        Variable<String>(CaptureWorkState.modelResultPersisted.wire),
        Variable<String>(_iso(t)),
        Variable<String>(captureUuid),
        Variable<int>(item.revision),
      ],
    );
    return updated > 0;
  }

  /// The stored result, if any. A caller that gets a value here MUST NOT call
  /// the model again — that is the "no second call after a persisted result"
  /// guarantee, and it is why this is checked before every dispatch.
  Future<String?> replayPersistedResult(String captureUuid) async =>
      (await find(captureUuid))?.modelResultJson;

  /// Record that an external model actually ran, even though its result was
  /// lost. Makes unavoidable duplicate execution VISIBLE instead of silent.
  Future<void> noteModelExecutionWithoutResult(String captureUuid) =>
      _db.customStatement(
        'UPDATE capture_work_items SET model_executions = model_executions + 1, '
        'updated_at = ? WHERE capture_uuid = ?;',
        [_iso(DateTime.now()), captureUuid],
      );

  Future<void> markTerminal({
    required String captureUuid,
    required CaptureWorkState state,
    String? transactionId,
    String? lastError,
    DateTime? now,
  }) =>
      _db.customStatement(
        'UPDATE capture_work_items SET state = ?, transaction_id = ?, '
        'last_error = ?, lease_owner = NULL, lease_expires_at = NULL, '
        'revision = revision + 1, updated_at = ? WHERE capture_uuid = ?;',
        [
          state.wire,
          transactionId,
          lastError,
          _iso(now ?? DateTime.now()),
          captureUuid,
        ],
      );

  /// Items whose lease expired — a crashed worker's work, reclaimable.
  Future<List<CaptureWorkItem>> reclaimable(DateTime now) async {
    final rows = await _db.customSelect(
      'SELECT * FROM capture_work_items WHERE lease_expires_at IS NOT NULL '
      'AND lease_expires_at < ? AND model_result_json IS NULL;',
      variables: [Variable<String>(_iso(now))],
    ).get();
    return rows.map(_map).toList();
  }

  /// Fingerprint matches — a duplicate SIGNAL for review, never an identity.
  Future<List<CaptureWorkItem>> withFingerprint(String fingerprint) async {
    final rows = await _db.customSelect(
      'SELECT * FROM capture_work_items WHERE content_fingerprint = ?;',
      variables: [Variable<String>(fingerprint)],
    ).get();
    return rows.map(_map).toList();
  }

  /// Consent revocation / wipe / account delete. Capture work items hold
  /// derived model output, so they are erased with everything else rather than
  /// surviving as an orphan record of a message the user asked to be forgotten.
  Future<int> deleteAll() =>
      _db.customUpdate('DELETE FROM capture_work_items;');

  Future<int> count() async {
    final rows = await _db
        .customSelect('SELECT COUNT(*) AS c FROM capture_work_items;')
        .get();
    return rows.first.read<int>('c');
  }
}
