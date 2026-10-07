import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Decision 10: cloud and AI consent are separate controls. No consent surface may
// grant both in a single action, i.e. call saveConsentChoice with both true.
void main() {
  test('no lib file grants cloud and AI in one saveConsentChoice call', () {
    final bothTrue = RegExp(
        r'saveConsentChoice\([^;]*?(cloud:\s*true[^;]*?ai:\s*true|ai:\s*true[^;]*?cloud:\s*true)',
        dotAll: true);
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (bothTrue.hasMatch(f.readAsStringSync())) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });

  test('the combined-grant label is not rendered by any consent surface', () {
    for (final path in [
      'lib/features/onboarding/onboarding_consent_steps.dart',
      'lib/features/consent/smart_analysis_consent_sheet.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('onbAiEnableBoth'), isFalse, reason: path);
      expect(src.contains('onbAiNeedsCloud'), isFalse, reason: path);
      expect(src.contains('smartConsentEnable'), isFalse, reason: path);
    }
  });
}
