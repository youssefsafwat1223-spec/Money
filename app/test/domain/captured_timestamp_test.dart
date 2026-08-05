// MALI-068n §11 — received-time authority: epoch preferred, ISO legacy-only,
// unknown → null (never `now`).
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/services/captured_timestamp.dart';

void main() {
  test('native epoch is authoritative and UTC', () {
    final at = resolveCapturedReceivedAt(epochMs: 1754400000000);
    expect(at, DateTime.fromMillisecondsSinceEpoch(1754400000000, isUtc: true));
    expect(at!.isUtc, isTrue);
  });

  test('epoch wins over a conflicting ISO string', () {
    final at = resolveCapturedReceivedAt(
      epochMs: 1754400000000,
      isoString: '2000-01-01T00:00:00Z',
    );
    expect(at!.millisecondsSinceEpoch, 1754400000000);
  });

  test('falls back to the ISO string only when no epoch (legacy items)', () {
    final at = resolveCapturedReceivedAt(isoString: '2026-08-05T09:00:00.000Z');
    expect(at, DateTime.utc(2026, 8, 5, 9));
  });

  test('missing everything is null — never stamped as now', () {
    expect(resolveCapturedReceivedAt(), isNull);
    expect(resolveCapturedReceivedAt(epochMs: 0, isoString: ''), isNull);
    expect(resolveCapturedReceivedAt(epochMs: -5), isNull);
  });

  test('a malformed ISO string is null, not an approximation', () {
    expect(resolveCapturedReceivedAt(isoString: 'not-a-date'), isNull);
    expect(resolveCapturedReceivedAt(isoString: '  '), isNull);
  });
}
