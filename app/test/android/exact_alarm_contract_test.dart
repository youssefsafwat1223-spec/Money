// MALI-068n §9 — source-contract checks for the Android exact-alarm posture.
// (A manifest/scheduler contract is inherently source-level; the behavioral
// coverage for scheduling lives in notification_capacity_planner_test.dart and
// the timestamp policy in captured_timestamp_test.dart.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final scheduler = File(
    'lib/features/capture/services/local_notification_service.dart',
  ).readAsStringSync();

  test('the Play-restricted exact-alarm permissions are NOT declared', () {
    // Match the actual <uses-permission> declaration, not the mention in the
    // explanatory comment.
    expect(
      manifest.contains('android.permission.USE_EXACT_ALARM" />'),
      isFalse,
    );
    expect(
      manifest.contains('android.permission.SCHEDULE_EXACT_ALARM" />'),
      isFalse,
    );
    expect(
      RegExp(r'<uses-permission[^>]*EXACT_ALARM').hasMatch(manifest),
      isFalse,
    );
  });

  test('reboot reschedule permission is retained', () {
    expect(manifest.contains('RECEIVE_BOOT_COMPLETED'), isTrue);
  });

  test('all reminder scheduling uses the inexact (never exact) mode', () {
    expect(scheduler.contains('AndroidScheduleMode.exactAllowWhileIdle'),
        isFalse);
    expect(scheduler.contains('AndroidScheduleMode.inexactAllowWhileIdle'),
        isTrue);
  });
}
