// MALI-039 — behavioral tests for the redacting diagnostic sink.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/diagnostics.dart';

void main() {
  group('Diag.redactLine', () {
    test('strips sensitive classes and bounds length', () {
      final out = Diag.redactLine(
        'ACME: paid 512.34 SAR on card 4417883322110099, '
        'token eyJabc.def.ghi at victim@example.com',
      );
      expect(out.contains('512.34'), isFalse);
      expect(out.contains('4417883322110099'), isFalse);
      expect(out.contains('eyJabc.def.ghi'), isFalse);
      expect(out.contains('victim@example.com'), isFalse);
    });

    test('truncates a pathologically long line with a marker', () {
      final long = List.filled(200, 'safeword').join(' ');
      final out = Diag.redactLine(long);
      expect(out.length, lessThanOrEqualTo(Diag.maxLineLength + 40));
      expect(out.contains('chars]'), isTrue);
    });
  });

  group('Diag.installRedactingSink', () {
    test('redacts every line before the underlying sink receives it', () {
      final captured = <String?>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
      try {
        // Wraps the capturing sink above.
        Diag.installRedactingSink();
        debugPrint('[Repo] failed: paid 512.34 on card 4417883322110099');
        expect(captured, hasLength(1));
        expect(captured.first!.contains('512.34'), isFalse);
        expect(captured.first!.contains('4417883322110099'), isFalse);
      } finally {
        debugPrint = original;
      }
    });
  });
}
