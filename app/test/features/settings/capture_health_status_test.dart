import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

void main() {
  test('capture health has no nudge without capture history', () {
    final status = CaptureHealthStatus(
      lastCaptureAt: null,
      now: DateTime.utc(2026, 7, 14),
    );

    expect(status.hasCaptureHistory, isFalse);
    expect(status.gap, isNull);
    expect(status.shouldNudge, isFalse);
  });

  test('capture health nudges after seven days since last capture', () {
    final status = CaptureHealthStatus(
      lastCaptureAt: DateTime.utc(2026, 7, 7),
      now: DateTime.utc(2026, 7, 14),
    );

    expect(status.hasCaptureHistory, isTrue);
    expect(status.gap, const Duration(days: 7));
    expect(status.shouldNudge, isTrue);
  });

  test('capture health does not nudge for recent captures', () {
    final status = CaptureHealthStatus(
      lastCaptureAt: DateTime.utc(2026, 7, 10),
      now: DateTime.utc(2026, 7, 14),
    );

    expect(status.gap, const Duration(days: 4));
    expect(status.shouldNudge, isFalse);
  });
}
