/// PHASE 9 — notification identity and content for a capture under review.
///
/// ## Stable identity, so an update replaces rather than stacks
///
/// A capture is notified while pending and again when it resolves. Those must
/// be the SAME notification: a user should see one row change, not two rows
/// accumulate. So the id is derived from the CAPTURE WORK ITEM identity — the
/// capture UUID from Phase 8 — and not from anything that changes as the
/// capture progresses.
///
/// Deriving it from the transaction id would break exactly when it matters: a
/// pending capture has no transaction yet, so the pending and resolved
/// notifications would land on different ids and stack.
///
/// ## Privacy
///
/// No raw SMS body ever appears in a notification. Bank messages contain card
/// suffixes, balances, reference numbers and sometimes names, and a
/// notification is the one surface that renders on a LOCKED screen where the
/// device owner may not be the person looking at it.
///
/// The lock-screen variant is stricter still: it names no amount, no merchant
/// and no bank, because those are the fields that make a glance informative to
/// a stranger.
library;

import '../../../domain/capture/capture_review_state.dart';

/// What a notification action asks the app to do. Deliberately a REQUEST, not
/// an instruction — see [CaptureNotificationActionRequest].
enum CaptureNotificationAction { review, confirm, dismiss }

/// A notification tap, expressed as something the domain layer must authorise.
///
/// ## Why this is inert data
///
/// A notification action arrives from outside the app's normal flow, possibly
/// long after it was posted, possibly after the user already edited the
/// transaction by hand. If the action could mutate the database directly it
/// would be able to resurrect a stale decision over newer user intent.
///
/// So this type carries no database handle and performs no work. It records
/// WHAT was requested and WHICH REVISION was on screen when it was posted, and
/// the Phase-10 CAS decides whether that is still valid.
class CaptureNotificationActionRequest {
  const CaptureNotificationActionRequest({
    required this.captureUuid,
    required this.action,
    required this.postedAtRevision,
  });

  final String captureUuid;
  final CaptureNotificationAction action;

  /// The work-item revision at the moment the notification was posted. A
  /// mismatch at apply time means the world moved on, and the action loses.
  final int postedAtRevision;

  /// True when newer state exists than the notification was posted against.
  ///
  /// A stale action must never overwrite a newer user edit — the user acting
  /// inside the app is a stronger signal than a tap on a banner that may have
  /// been sitting in the shade for hours.
  bool isStaleAgainst(int currentRevision) => postedAtRevision < currentRevision;
}

class CaptureReviewNotification {
  const CaptureReviewNotification._();

  /// Stable per capture work item, so pending → resolved UPDATES in place.
  ///
  /// The channel prefix keeps this from colliding with the existing
  /// transaction-id-derived ids used elsewhere.
  static int notificationIdFor(String captureUuid) {
    // FNV-1a over the uuid, folded into the positive 31-bit range platform
    // notification ids accept. Deterministic: the same capture always maps to
    // the same id, which is what makes replacement work.
    var hash = 0x811c9dc5;
    for (final unit in 'capture_review:$captureUuid'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// Whether a state should be shown at all.
  ///
  /// Transient states are not worth interrupting someone for: a capture that is
  /// merely waiting on the model will resolve on its own, and notifying for it
  /// would train people to ignore the channel.
  static bool shouldNotify(CaptureReviewState state) =>
      state == CaptureReviewState.proven || state.needsUserDecision;

  /// Body text for a review notification. NEVER the SMS.
  ///
  /// [lockScreenSafe] drops the amount as well, for the public/locked variant.
  static String bodyFor(
    CaptureReviewState state, {
    String? amountLabel,
    bool lockScreenSafe = false,
  }) {
    if (lockScreenSafe) {
      // No amount, no merchant, no bank — nothing a stranger glancing at a
      // locked screen learns about this person's finances.
      return switch (state) {
        CaptureReviewState.proven => 'عملية جديدة بانتظار التأكيد',
        _ => 'عملية تحتاج مراجعة',
      };
    }
    final amount = amountLabel == null ? '' : ' $amountLabel';
    return switch (state) {
      CaptureReviewState.proven => 'اضغط لتأكيد العملية$amount.',
      CaptureReviewState.amountConflict =>
        'أكثر من مبلغ محتمل — اختر المبلغ الصحيح.',
      CaptureReviewState.currencyConflict => 'العملة غير واضحة — راجع العملية.',
      CaptureReviewState.directionAmbiguous =>
        'لم نتأكد إن كانت واردة أم صادرة.',
      CaptureReviewState.directionConflict =>
        'إشارات متضاربة عن اتجاه العملية — راجعها.',
      CaptureReviewState.categoryAmbiguous => 'اختر تصنيف العملية$amount.',
      _ => 'راجع العملية.',
    };
  }
}
