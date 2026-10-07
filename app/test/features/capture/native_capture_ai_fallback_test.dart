import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/capture_notification_authority.dart';
import 'package:money_companion/features/capture/services/native_capture_ai_fallback.dart';

void main() {
  bool run({
    String? status = 'sent',
    String? failure = 'http_500',
    bool flag = true,
    bool ai = true,
  }) =>
      nativeCaptureMayUseAiFallback(
        status: status,
        failureReason: failure,
        flagEnabled: flag,
        aiAllowed: ai,
      );

  test('sent + failureReason + flag + consent allows the AI fallback', () {
    expect(run(), isTrue);
  });

  test('any missing condition keeps the drain on-device only', () {
    expect(run(flag: false), isFalse);
    expect(run(ai: false), isFalse);
    expect(run(failure: null), isFalse);
    expect(run(failure: ''), isFalse);
    expect(run(failure: '  '), isFalse);
    expect(run(status: 'pendingSend'), isFalse);
    expect(run(status: null), isFalse);
    expect(run(status: 'received'), isFalse);
  });

  test(
      'Astra H1 build-50 fallback: a 409 refusal (owner conflict / mismatch) '
      'never reaches AI, even with the flag ON and consent granted', () {
    expect(run(failure: 'http(409)'), isFalse);
    expect(run(failure: ' http(409) '), isFalse);
    // Control: any other backend failure keeps the existing rule.
    expect(run(failure: 'http(500)'), isTrue);
  });

  test('a `sent` capture never gets a second local banner', () {
    expect(
      CaptureNotificationAuthority.shouldShowLocalReview(
        status: 'sent',
        alreadyImported: false,
        ownerValid: true,
      ),
      isFalse,
    );
  });
}
