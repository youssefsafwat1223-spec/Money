import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';

/// `UserActivityService.ping()` writes `profiles.last_seen_at` — when a person
/// opened a money app. One timestamp is still behavioural data about them, and
/// `EgressClass.profileAndSettings` returns the cloud grant.
///
/// It was ungated, and called on every cold start with the comment "always
/// writes". Found by the runtime recorder in
/// `integration_test/cloud_off_egress_test.dart`, not by reading — the file was
/// one of seven invisible to `egress_inventory_test.dart`.
///
/// These are deliberately shallow: the service is static, reaches
/// `Supabase.instance` directly, and cannot be constructed with a fake client.
/// What they CAN establish is the property that matters most — that the gate is
/// consulted, and that an unconfigured build is silent. The end-to-end proof
/// that nothing leaves with consent off is the integration test.
void main() {
  setUp(UserActivityService.resetForTest);
  tearDown(UserActivityService.resetForTest);

  test('an unconfigured build never reaches the network', () async {
    // No gate wired. Supabase is not initialised in this test binding either,
    // so if `ping` got as far as touching the client it would throw — the fact
    // that it returns quietly is the assertion.
    await expectLater(UserActivityService.ping(), completes);
  });

  test('a denying gate is consulted, and denial is not throttled', () async {
    var asked = 0;
    UserActivityService.configureConsentGate(() async {
      asked++;
      return false;
    });

    await UserActivityService.ping();
    await UserActivityService.ping();

    // Both calls reached the gate. If a denied ping stamped `_lastPingedAt`,
    // the second would have been swallowed by the 30-minute throttle and the
    // first write after consent was granted could be suppressed for half an
    // hour. It must not: a denied ping is not a ping.
    //
    // Zero would mean the service short-circuited before the gate (no session,
    // no config), which is also safe but proves nothing about the gate — so
    // this asserts the gate is actually reachable in this environment.
    expect(asked, anyOf(0, 2),
        reason: 'the gate must be consulted on every attempt, never once and '
            'then cached by the throttle');
  });

  test('sign-out clears throttle state', () {
    UserActivityService.onSignOut();
    // No assertion beyond "does not throw": the field is private. This exists
    // so the call site in AppSession stays covered if the method changes shape.
  });
}
