import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Astra R45 R11 — dependency-contract guard. The startup provenance observation
// (`ObservingAuthLocalStorage`, `AuthInitEventBuffer`) depends on the locked SDK:
//   * `Supabase.initialize` derives the default session key
//     `sb-<first host label>-auth-token` and initializes the session store BEFORE
//     it emits the initial session or runs the (unawaited) recovery;
//   * `GoTrueClient.setInitialSession` / `recoverSession` read the store through
//     `hasAccessToken()` / `accessToken()` and degrade a malformed state to a
//     plain null initial session.
// The behavioural proof lives in `test/core/startup/auth_init_provenance_test.dart`
// (real `Supabase.initialize`). This test makes an SDK upgrade FAIL until that
// contract is re-reviewed: bump the versions below only together with that review.

String _lockedVersion(String package) {
  final lock = File('pubspec.lock').readAsStringSync();
  final match = RegExp(
    '^  $package:\\n(?:    .*\\n)*?    version: "([^"]+)"',
    multiLine: true,
  ).firstMatch(lock);
  expect(match, isNotNull, reason: '$package is locked');
  return match!.group(1)!;
}

void main() {
  test('the SDK versions the startup observation was reviewed against', () {
    expect(_lockedVersion('supabase_flutter'), '2.14.2',
        reason: 'review the storage key derivation and initialization order '
            '(auth_init_provenance_test.dart) before changing this version');
    expect(_lockedVersion('gotrue'), '2.21.0',
        reason: 'review setInitialSession / recoverSession error handling '
            'before changing this version');
  });

  test(
      'startup uses the observing store with the SDK-derived key, never a '
      'hand-written one', () {
    final src =
        File('lib/core/startup/bootstrap_runner.dart').readAsStringSync();
    expect(src,
        contains('ObservingAuthLocalStorage(_initEvents, SupabaseConfig.url)'));
    expect(src,
        contains("'sb-\${Uri.parse(url).host.split('.').first}-auth-token'"),
        reason: 'the single reviewed derivation');
    expect(RegExp(r"'sb-[A-Za-z0-9]+-auth-token'").hasMatch(src), isFalse,
        reason: 'no hard-coded project key');
  });
}
