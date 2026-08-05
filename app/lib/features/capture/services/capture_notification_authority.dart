// MALI-061n §12 — ONE authority for a capture's review notification.
//
// A single bank capture can arrive through several paths — the Android SMS
// receiver, the iOS App Intent local preview, an APNs capture push, the Share
// Extension, and the Flutter import/review drain. Exactly one of them may notify
// for a given logical capture. The shared logical identity is the capture
// PAYLOAD ID (also the durable import-dedup key), and the review notification's
// id is derived from the transaction id (`notificationEventId('review', …)`), so
// even a racing double-fire collapses to one banner instead of stacking.
//
// This pure predicate centralizes the decision so it is directly testable; the
// app_shell drain calls it at the single point where it would show a local
// review notification.
library;

class CaptureNotificationAuthority {
  const CaptureNotificationAuthority._();

  /// Native capture lifecycle status meaning the native side (App Intent / APNs
  /// preview) ALREADY presented a notification for this capture.
  static const String statusAlreadyNotified = 'sent';

  /// Whether the LOCAL Flutter path should present the review notification.
  ///
  /// Returns false when:
  ///   * the owner is invalid (sign-out / ownership change) — never surface a
  ///     stale capture for the previous user;
  ///   * the native side already notified (`status == 'sent'`) — the App Intent
  ///     / APNs preview owns it, so the local path must not double-notify;
  ///   * the payload was already imported on a prior run — a duplicate/replay is
  ///     acknowledged and skipped, never re-notified.
  ///
  /// A LOST APNs response leaves the status NOT 'sent', so the local path still
  /// fires — losing the response never suppresses both paths.
  static bool shouldShowLocalReview({
    required String? status,
    required bool alreadyImported,
    required bool ownerValid,
  }) {
    if (!ownerValid) return false;
    if (status == statusAlreadyNotified) return false;
    if (alreadyImported) return false;
    return true;
  }
}
