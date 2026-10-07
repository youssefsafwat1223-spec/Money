import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/validated_capture.dart';

// Runs the SAME golden file as the server test
// supabase/functions/_shared/validated_capture_contract_test.ts. A disagreement
// between the two validators must be reported, never papered over here.
const _fixturePath = '../contract_fixtures/validated_capture_v1.json';
final _receivedAt = DateTime.utc(2026, 6, 16, 12);

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('validated_capture_v1 fixture version', () {
    expect(fixture['version'], 1);
    expect(cases, isNotEmpty);
  });

  for (final c in cases) {
    test('validated_capture_v1: ${c['id']}', () {
      final cand = c['candidate'] as Map<String, dynamic>;
      final expected = c['expected'] as Map<String, dynamic>;
      final out = validateCaptureCandidate(
        candidate: CaptureCandidate(
          amount: (cand['amount'] as num?)?.toDouble(),
          amountText: cand['amount_text'] as String?,
          currency: cand['currency'] as String?,
          direction: cand['direction'] as String?,
          type: cand['type'] as String?,
          merchant: cand['merchant'] as String?,
          last4: cand['last4'] as String?,
          occurredAt: cand['occurred_at'] as String?,
        ),
        text: c['text'] as String,
        receivedAt: _receivedAt,
      );
      expect(out.accepted, expected['valid']);
      if (!out.accepted) {
        expect(out.reason, expected['reason']);
        return;
      }
      final v = out.capture!;
      final kept = <String>[
        if (v.merchant != null) 'merchant',
        if (v.last4 != null) 'last4',
        if (v.occurredAt != null) 'occurred_at',
      ];
      expect(kept, (expected['kept_fields'] as List?) ?? const []);
    });
  }
}
