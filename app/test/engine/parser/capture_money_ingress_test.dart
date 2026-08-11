import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/capture_money.dart';

void main() {
  test('canonical mode routes old numeric backend response to pending review',
      () {
    expect(
      resolveAiCaptureIngress(hasExactText: false, canonicalMode: true),
      AiCaptureIngress.legacyPendingReview,
    );
  });

  test('canonical mode allows exact amount_text into canonical authority', () {
    expect(
      resolveAiCaptureIngress(hasExactText: true, canonicalMode: true),
      AiCaptureIngress.canonicalExact,
    );
  });

  test('non-canonical v29 mode preserves exact-first numeric-review behavior',
      () {
    expect(
      resolveAiCaptureIngress(hasExactText: false, canonicalMode: false),
      AiCaptureIngress.legacyPendingReview,
    );
    expect(
      resolveAiCaptureIngress(hasExactText: true, canonicalMode: false),
      AiCaptureIngress.canonicalExact,
    );
  });
}
