import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// MALI-023: typed classification of an outbox push failure, so the queue can
/// apply the right recovery instead of the old "always eligible + reset to 1"
/// hot loop. Each named class the audit called for maps onto one of three
/// behaviours:
///
/// - **retryable** (transient network, rate-limit, auth/session, server 5xx,
///   missing-dependency): bounded exponential backoff, stays `pending`.
/// - **conflict** (stale revision / unique-constraint): NOT a generic retry —
///   the push marks the entity `conflict`; the outbox row is consumed.
/// - **permanent** (validation 4xx, unsupported schema/version, corrupted
///   payload): moved to the `dead_letter` terminal state immediately — no retry
///   storm. A later app/schema-version change may explicitly re-arm it.
enum OutboxFailureClass {
  transientNetwork,
  rateLimit,
  auth,
  serverError,
  missingDependency,
  conflict,
  permanentValidation,
  unsupportedSchema,
  corruptedPayload,

  /// A-3 (G16): a unique constraint OTHER than the entity's own idempotency key
  /// rejected the write (e.g. card account+last4, category key). Never resolved
  /// by replacing local data; parked observably as a dead letter.
  duplicateBusinessKey,

  /// A-3: 42P10 — the server has no unique/exclusion constraint matching the
  /// ON CONFLICT target. A server/client schema mismatch, not a data conflict.
  serverSchemaMismatch,

  /// A-3: 23514 — a server CHECK constraint rejected the row.
  serverCheckViolation;

  /// A permanent failure is dead-lettered immediately (no retry).
  bool get isPermanent =>
      this == permanentValidation ||
      this == unsupportedSchema ||
      this == corruptedPayload ||
      this == duplicateBusinessKey ||
      this == serverSchemaMismatch ||
      this == serverCheckViolation;

  /// The observable reason stored in `failure_class` (SyncHealth breakdown).
  /// The A-3 classes use stable snake_case reasons; older classes keep [name].
  String get reason => switch (this) {
        duplicateBusinessKey => kFailDuplicateBusinessKey,
        serverSchemaMismatch => kFailServerSchemaMismatch,
        serverCheckViolation => kFailServerCheckViolation,
        _ => name,
      };

  /// A conflict is resolved by the conflict pathway, never by markFailed retry.
  bool get isConflict => this == conflict;
}

/// MALI-052n: fold an incoming op into an existing pending outbox row for the
/// same entity, so N consecutive offline edits become ONE row carrying ONE base
/// token (never self-conflicting). Returns the resulting operation, or null when
/// the row should be dropped entirely (a create cancelled by a delete before it
/// ever reached the server). A-3: callers must NOT drop when the row's durable
/// `in_flight_seq` is set — the create may have reached the server.
String? coalesceOutboxOperation(String existing, String incoming) {
  if (incoming == 'delete') {
    return existing == 'create' ? null : 'delete';
  }
  // incoming is create or update: a queued create stays a create (carry the
  // latest field values); otherwise the incoming op replaces the pending one.
  if (existing == 'create') return 'create';
  return incoming;
}

const String kFailDuplicateBusinessKey = 'duplicate_business_key';
const String kFailServerSchemaMismatch = 'server_schema_mismatch';
const String kFailServerCheckViolation = 'server_check_violation';

/// A-3: true when [e] is a unique-violation (23505) raised by the entity's OWN
/// idempotency key (for example `(user_id, local_id)`), as opposed to some other
/// unique constraint. Decided from the structured `details`
/// ("Key (user_id, local_id)=(...) already exists.") or the constraint name in
/// `message`; callers that cannot tell from the error re-query the server.
bool isIdempotencyKeyViolation(
  PostgrestException e, {
  required String keyColumns,
  Iterable<String> constraintNames = const [],
}) {
  if (e.code != '23505') return false;
  final details = (e.details?.toString() ?? '').replaceAll(' ', '');
  if (details.contains('Key($keyColumns)=') ||
      details.contains('Key(${keyColumns.replaceAll(' ', '')})=')) {
    return true;
  }
  final msg = e.message;
  return constraintNames.any(msg.contains);
}

/// A-3: a genuine optimistic-concurrency conflict signalled by the transport
/// (HTTP 409 / PostgREST code '409'). Everything else — including 23505 — is
/// classified by [classifyOutboxError], never by message text.
bool isTransportConflict(Object e) =>
    e is PostgrestException && e.code == '409';

/// A-2 (G18): park reasons recorded in `failure_class` of a `parked` outbox row.
/// Parked rows are never sent, never deleted and never consume a retry attempt;
/// each is self-healing (re-evaluated at the start of the next push cycle) and
/// observable through SyncHealth.queueCounts.
///
/// The row was recorded for a DIFFERENT local-data owner than the identity that
/// is currently authenticated. Re-armed only when the owner signs back in.
const String kParkOwnerMismatch = 'owner_mismatch';

/// A legacy row (no owner uid) whose local-data ownership for the current
/// identity is not verified as `owned`. Never uploaded under an unverified uid.
const String kParkOwnerUnverified = 'owner_unverified';

/// The row depends on something that does not exist yet (budget category,
/// card account, bound settings row). Unparked once the dependency resolves.
const String kParkDependencyWait = 'dependency_wait';

/// A-6: a confirmed awaiting-FX transaction (amount 0 + foreign amount/currency)
/// is held until the server is verified to accept that shape. Never sent, never
/// dead-lettered, never consumes an attempt. Re-armed by the capability service
/// (verified), and coalescible so a later priced edit folds into the same row.
const String kParkAwaitingServerFxSupport = 'awaiting_server_fx_support';

/// Park reasons owned by the outbox-correctness layer (as opposed to the
/// exact-money-transport reason, which is re-armed by a verified capability).
/// Excluded from the generic `reArmParked` and coalescible.
const Set<String> kOutboxSelfHealingParkReasons = {
  kParkOwnerMismatch,
  kParkOwnerUnverified,
  kParkDependencyWait,
  kParkAwaitingServerFxSupport,
};

/// SQL list literal of [kOutboxSelfHealingParkReasons].
const String kOutboxSelfHealingParkReasonsSql =
    "('$kParkOwnerMismatch','$kParkOwnerUnverified','$kParkDependencyWait',"
    "'$kParkAwaitingServerFxSupport')";

/// MALI-023: after this many retryable failures a row is dead-lettered so a
/// permanently-failing item can never hot-loop. Re-armable on app/schema upgrade.
const int kOutboxMaxAttempts = 12;

/// Maps a thrown push error onto an [OutboxFailureClass]. Never inspects
/// financial payload contents — only error type / status code / message shape.
/// Replaces the old string-match-on-'duplicate'/'409' classification.
OutboxFailureClass classifyOutboxError(Object error) {
  if (error is SocketException || error is HttpException) {
    return OutboxFailureClass.transientNetwork;
  }
  if (error is StateError) {
    // Child push guards throw StateError('..._parent_not_synced') when a parent
    // hasn't reached the server yet — a transient missing dependency.
    final m = error.message.toLowerCase();
    if (m.contains('parent') || m.contains('not_synced')) {
      return OutboxFailureClass.missingDependency;
    }
    return OutboxFailureClass.transientNetwork;
  }
  if (error is PostgrestException) {
    final code = error.code ?? '';
    // PostgREST/Postgres SQLSTATE-ish codes.
    if (code == '409') return OutboxFailureClass.conflict;
    // A-3: a unique violation that reaches here was NOT the entity's own
    // idempotency key (push services handle that replay first) — a business-key
    // duplicate, never auto-resolved.
    if (code == '23505') return OutboxFailureClass.duplicateBusinessKey;
    if (code == '42P10') return OutboxFailureClass.serverSchemaMismatch;
    if (code == '23514') return OutboxFailureClass.serverCheckViolation;
    if (code == '429') return OutboxFailureClass.rateLimit;
    if (code == '401' || code == '403' || code == '42501') {
      return OutboxFailureClass.auth;
    }
    if (code.startsWith('5')) return OutboxFailureClass.serverError;
    if (code == '23502' ||
        code == '22P02' ||
        code == '22023') {
      // not-null / check / invalid-text / invalid-parameter-value. The last
      // (22023) is raised by record_engagement_event for an unknown event type
      // or unsupported event version — a permanent client-side validation error.
      return OutboxFailureClass.permanentValidation;
    }
    if (code == '23503') return OutboxFailureClass.missingDependency; // FK
    if (code == '42703' || code == '42P01' || code == 'PGRST204') {
      return OutboxFailureClass.unsupportedSchema; // unknown column/table/schema-cache
    }
    // A-3: no message matching — an unknown code is a server error (retryable).
    return OutboxFailureClass.serverError;
  }
  if (error is FormatException || error is TypeError) {
    return OutboxFailureClass.corruptedPayload;
  }
  final msg = error.toString().toLowerCase();
  if (msg.contains('socket') ||
      msg.contains('timeout') ||
      msg.contains('network') ||
      msg.contains('connection')) {
    return OutboxFailureClass.transientNetwork;
  }
  if (msg.contains('429') || msg.contains('rate limit')) {
    return OutboxFailureClass.rateLimit;
  }
  if (msg.contains('401') || msg.contains('403') || msg.contains('jwt')) {
    return OutboxFailureClass.auth;
  }
  // Unknown → treat as transient (retry with backoff) rather than dead-letter,
  // so a novel-but-recoverable error is never silently discarded.
  return OutboxFailureClass.transientNetwork;
}
