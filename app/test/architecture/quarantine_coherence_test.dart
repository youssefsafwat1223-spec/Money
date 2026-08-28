import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tests and the code they cover must land TOGETHER.
///
/// ## Why this exists
/// Some workstreams in this repo are deliberately quarantined — implemented in
/// the working tree but NOT committed, because review rejected them
/// (`QIRSH_MASTER_PLAN_V2.md` §12.2, §8a). Their tests live beside them.
///
/// Three separate times during the 2026-08-28 remediation run, a file carrying
/// BOTH landed work and quarantined tests was staged whole with `git add`, which
/// carried the quarantined tests into the committed tree without their
/// implementation. The result each time: green locally, red at HEAD.
///
/// That failure mode is uniquely nasty because it is invisible from the working
/// tree — the tree has the implementation, so the tests pass there and nothing
/// suggests a problem. It is only visible by running the suite at committed HEAD
/// in a clean checkout, which is not what anyone does by habit.
///
/// A test asserting behaviour the committed tree does not have is worse than no
/// test: it reports a defect that does not exist in what actually ships, and it
/// teaches the next person to read a red suite as noise.
///
/// So this asserts the pairing directly, in the committed tree, where it is
/// cheap to check and impossible to miss.
void main() {
  /// test file → a symbol that must exist in the implementation for its tests
  /// to be meaningful.
  const pairings = <String, ({String impl, String symbol, String finding})>{
    'test/features/planning_sync/accounts_sync_service_test.dart': (
      impl: 'lib/features/planning_sync/services/accounts_pull_service.dart',
      symbol: '_serverDivergedFromLocal',
      finding: 'F-021 pull half (QUARANTINED — DO NOT LAND, §12.2)',
    ),
  };

  /// The marker that identifies a quarantined test inside a shared file.
  const markers = <String, String>{
    'test/features/planning_sync/accounts_sync_service_test.dart': 'F-021:',
  };

  test('no test covers an implementation that is not committed', () {
    for (final entry in pairings.entries) {
      final testSrc = File(entry.key).readAsStringSync();
      final marker = markers[entry.key]!;
      final hasTests = testSrc.contains(marker);
      if (!hasTests) continue;

      final implSrc = File(entry.value.impl).readAsStringSync();
      expect(
        implSrc.contains(entry.value.symbol),
        isTrue,
        reason: '${entry.key} contains "$marker" tests, but '
            '${entry.value.impl} does not define ${entry.value.symbol}.\n\n'
            'This is ${entry.value.finding}. The tests were committed without '
            'the code they cover — they will pass in a working tree that has '
            'the uncommitted implementation and FAIL at HEAD.\n\n'
            'Either land the implementation, or remove these tests from the '
            'commit. They belong together.',
      );
    }
  });

  test('the pairing map points at files that exist', () {
    for (final entry in pairings.entries) {
      expect(File(entry.key).existsSync(), isTrue, reason: entry.key);
      expect(File(entry.value.impl).existsSync(), isTrue,
          reason: entry.value.impl);
    }
  });
}
