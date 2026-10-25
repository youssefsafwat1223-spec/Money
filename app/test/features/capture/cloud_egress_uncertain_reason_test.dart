import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

void main() {
  test('uncertain keeps the native reason constant', () {
    final s = CloudEgressSnapshot.tryParse(
        {'status': 'uncertain', 'reason': 'epoch_missing'})!;
    expect(s.uncertain, isTrue);
    expect(s.uncertainReason, 'epoch_missing');
  });

  test('a missing or non-constant reason is dropped, status still uncertain',
      () {
    for (final reason in [null, 7, '', 'has space', 'UID-123', 'a' * 80]) {
      final s = CloudEgressSnapshot.tryParse(
          {'status': 'uncertain', if (reason != null) 'reason': reason})!;
      expect(s.uncertain, isTrue);
      expect(s.uncertainReason, isNull, reason: '$reason');
    }
  });
}
