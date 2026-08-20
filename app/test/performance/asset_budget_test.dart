// Phase-7 Batch-2 §MALI-038 / §11 — packaged-asset size budgets. Guards against a
// large raster sneaking back into the bundle (the two ~5MB/2MB unreferenced
// onboarding backgrounds were removed in B2). Structural budget, not wall-clock:
// a per-file ceiling and a total ceiling over the on-disk assets/ tree.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Budgets (bytes). Set with headroom over the current real values so ordinary
  // edits pass but a multi-MB raster or a doubling of the payload fails.
  // B2-D reconciliation: the four bundled Alexandria TTFs add ~673 KiB, so the
  // assets/ total moved 7.81 MiB → ~8.47 MiB (the bundled fonts total ~1.63 MiB:
  // Alexandria ~673 KiB + IBM Plex Sans Arabic ~948 KiB). Largest single asset
  // is still ~801 KiB (a qirsh logo PNG). The 11 MiB ceiling is UNCHANGED — it
  // still leaves ~2.5 MiB (≈23%) regression margin — rather than raising it to
  // accommodate the fonts.
  // Vazirmatn primary-family switch: four more TTFs at ~120 KiB each (+~0.48
  // MiB, total ~8.95 MiB). Ceiling still 11 MiB — ~2 MiB (≈19%) margin remains.
  const perFileMax = 1024 * 1024; // 1 MiB — no single packaged asset may exceed
  const totalMax = 11 * 1024 * 1024; // ~11 MiB — whole assets/ tree ceiling

  final assetsDir = Directory('assets');

  test('assets/ exists (test runs from the Flutter project root)', () {
    expect(assetsDir.existsSync(), isTrue);
  });

  test('all four bundled weights of each UI family are packaged', () {
    for (final family in const ['Vazirmatn', 'Alexandria']) {
      for (final w in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        final f = File('assets/fonts/$family-$w.ttf');
        expect(f.existsSync(), isTrue, reason: 'missing $family-$w.ttf');
        // Sanity: a real, non-trivial TrueType file (magic 0x00010000).
        final head = f.openSync().readSync(4);
        expect(head, orderedEquals(const [0x00, 0x01, 0x00, 0x00]),
            reason: '$family-$w.ttf is not a TrueType file');
      }
    }
  });

  test('no single packaged asset exceeds the per-file budget', () {
    final offenders = <String>[];
    for (final e in assetsDir.listSync(recursive: true)) {
      if (e is! File) continue;
      final size = e.lengthSync();
      if (size > perFileMax) {
        offenders.add('${e.path} = ${(size / 1024).round()} KiB');
      }
    }
    expect(offenders, isEmpty,
        reason: 'assets over ${perFileMax ~/ 1024} KiB — compress or drop:\n'
            '${offenders.join('\n')}');
  });

  test('total packaged asset payload stays within budget', () {
    var total = 0;
    for (final e in assetsDir.listSync(recursive: true)) {
      if (e is File) total += e.lengthSync();
    }
    expect(total, lessThanOrEqualTo(totalMax),
        reason:
            'assets/ total is ${(total / (1024 * 1024)).toStringAsFixed(1)} '
            'MiB, over the ${totalMax ~/ (1024 * 1024)} MiB budget');
  });
}
