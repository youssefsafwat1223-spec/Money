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
  corruptedPayload;

  /// A permanent failure is dead-lettered immediately (no retry).
  bool get isPermanent =>
      this == permanentValidation ||
      this == unsupportedSchema ||
      this == corruptedPayload;

  /// A conflict is resolved by the conflict pathway, never by markFailed retry.
  bool get isConflict => this == conflict;
}

/// MALI-052n: fold an incoming op into an existing pending outbox row for the
/// same entity, so N consecutive offline edits become ONE row carrying ONE base
/// token (never self-conflicting). Returns the resulting operation, or null when
/// the row should be dropped entirely (a create cancelled by a delete before it
/// ever reached the server).
String? coalesceOutboxOperation(String existing, String incoming) {
  if (incoming == 'delete') {
    return existing == 'create' ? null : 'delete';
  }
  // incoming is create or update: a queued create stays a create (carry the
  // latest field values); otherwise the incoming op replaces the pending one.
  if (existing == 'create') return 'create';
  return incoming;
}

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
    if (code == '23505' || code == '409') return OutboxFailureClass.conflict;
    if (code == '429') return OutboxFailureClass.rateLimit;
    if (code == '401' || code == '403') return OutboxFailureClass.auth;
    if (code.startsWith('5')) return OutboxFailureClass.serverError;
    if (code == '23502' ||
        code == '23514' ||
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
    // Fall back on the message for versions that don't populate `code`.
    final msg = error.message.toLowerCase();
    if (msg.contains('duplicate') || msg.contains('conflict')) {
      return OutboxFailureClass.conflict;
    }
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
