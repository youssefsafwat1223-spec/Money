// MALI-061n §12 — capture notification single-authority contract.
//
// The review-notification IDENTITY dedup (stable `review:<txnId>` id so a racing
// double-fire collapses to one banner) is covered in notification_planner_test
// (notificationEventId); the durable payload-id replay dedup is covered in
// capture_sync_service_test (isPayloadImported). This file proves the AUTHORITY
// decision — which single path may notify a given capture.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/capture_notification_authority.dart';

void main() {
  bool decide({
    String? status,
    bool alreadyImported = false,
    bool ownerValid = true,
  }) =>
      CaptureNotificationAuthority.shouldShowLocalReview(
        status: status,
        alreadyImported: alreadyImported,
        ownerValid: ownerValid,
      );

  test('APNs / App Intent already notified (status=sent) → local suppressed',
      () {
    expect(decide(status: 'sent'), isFalse);
  });

  test('APNs failure or LOST response (status != sent) → local still fires', () {
    // A lost APNs response leaves the capture NOT marked sent — the local path
    // must NOT be suppressed, so the user is never left with no notification.
    expect(decide(status: 'pendingSend'), isTrue);
    expect(decide(status: null), isTrue);
    expect(decide(status: 'failed'), isTrue);
  });

  test('a duplicate/replayed (already-imported) capture is never re-notified',
      () {
    expect(decide(status: null, alreadyImported: true), isFalse);
  });

  test('sign-out / ownership change blocks a stale capture notification', () {
    // Owner-invalid wins even over a would-be-showable status.
    expect(decide(status: null, ownerValid: false), isFalse);
    expect(decide(status: 'pendingSend', ownerValid: false), isFalse);
  });

  test('a fresh, owned, not-yet-notified capture shows exactly once', () {
    expect(decide(status: null, alreadyImported: false, ownerValid: true),
        isTrue);
  });
}
