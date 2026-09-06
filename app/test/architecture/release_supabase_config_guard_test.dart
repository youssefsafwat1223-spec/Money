import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A shipping build can never be Supabase-UNCONFIGURED.
///
/// Review raised that `syncCatalog` returns before the forced parser-authority
/// refresh when `SupabaseConfig.isConfigured` is false, so an unconfigured
/// install would keep legacy parser authority. Rather than complicate
/// production runtime for a state that cannot ship, this pins the build-time
/// guarantee that makes it impossible: every workflow that produces an
/// installable artifact asserts SUPABASE_URL and SUPABASE_ANON_KEY are
/// non-empty and exits non-zero otherwise.
///
/// If that assertion is ever removed, the runtime assumption stops holding —
/// so this test fails instead.
void main() {
  final yaml = File('../codemagic.yaml').readAsStringSync();

  /// Split the file into top-level workflow blocks.
  Map<String, String> workflows() {
    final out = <String, String>{};
    final matches = RegExp(r'^  ([a-z0-9-]+):$', multiLine: true)
        .allMatches(yaml)
        .toList();
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length ? matches[i + 1].start : yaml.length;
      out[matches[i].group(1)!] = yaml.substring(start, end);
    }
    return out;
  }

  /// Workflows that produce something a person can install.
  const shipping = [
    'ios-unsigned-sideload',
    'ios-signed-release',
    'android-release',
  ];

  group('no shipping build can be Supabase-unconfigured', () {
    test('every shipping workflow exists', () {
      final found = workflows();
      for (final w in shipping) {
        expect(found.containsKey(w), isTrue,
            reason: '$w is gone — update this guard deliberately');
      }
    });

    test('each asserts non-empty SUPABASE_URL and ANON_KEY, and fails hard', () {
      final found = workflows();
      for (final w in shipping) {
        final body = found[w]!;
        expect(body, contains(r'${SUPABASE_URL:-}'),
            reason: '$w no longer checks SUPABASE_URL');
        expect(body, contains(r'${SUPABASE_ANON_KEY:-}'),
            reason: '$w no longer checks SUPABASE_ANON_KEY');
        expect(body, contains('exit 1'),
            reason: '$w checks the config but does not fail the build');
      }
    });

    test('the assertion runs BEFORE the build step that consumes it', () {
      // A check that runs after the artifact is built proves nothing.
      final found = workflows();
      for (final w in shipping) {
        final body = found[w]!;
        final assertAt = body.indexOf('Assert production Supabase config');
        final buildAt =
            body.indexOf(RegExp(r'flutter build (ios|ipa|apk|appbundle)'));
        expect(assertAt, isNot(-1), reason: '$w lost the assertion step');
        expect(buildAt, isNot(-1), reason: '$w lost its build step');
        expect(assertAt, lessThan(buildAt),
            reason: '$w asserts config only AFTER building');
      }
    });

    test('the runtime gate this relies on still exists', () {
      // The guard is only meaningful because the app reads these at build time.
      final config =
          File('lib/core/backend/supabase_config.dart').readAsStringSync();
      expect(config, contains("String.fromEnvironment('SUPABASE_URL')"));
      expect(config, contains("String.fromEnvironment('SUPABASE_ANON_KEY')"));
      expect(config, contains('url.isNotEmpty && anonKey.isNotEmpty'));
    });
  });
}
