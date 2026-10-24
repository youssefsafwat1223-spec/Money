// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/capture/ledger_admission_fixture.dart';

// Astra D6 — the process-lifetime sender-bank auth listener is a retained global
// listener: it survives the in-process swap from the writable scope to the
// read-only one. While the session denies egress it must sync nothing (no
// consent read, no remote call); once local read ends it works again.

String _jwt(String uid, int exp) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': exp})}.';
}

void main() {
  test('sender-bank sync is silent while egress is denied and alive afterwards',
      () async {
    // The positive control must hold the real host's committed admission;
    // an unrelated in-memory database is correctly refused before consent reads.
    final probe = LedgerDatabaseProbe();
    final fixture = await LedgerAdmissionFixture.open('uid-sb', probe);
    addTearDown(fixture.finish);
    final db = fixture.database;
    final session = fixture.fixture.session;
    expect(session.captureLocalWorkAuthority()?.isCurrent, isTrue);
    expect(await AccountFenceAuthority.shared.captureForDatabase(session, db),
        isNotNull);
    var settingsReads = 0;
    final positiveRead = Completer<void>();
    probe.afterSelect = (statement) async {
      if (statement.contains('user_settings')) {
        settingsReads++;
        if (!positiveRead.isCompleted) positiveRead.complete();
      }
    };
    var requests = 0;
    final client = fixture.ownClient(SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(
              jsonEncode({
                'access_token': _jwt(
                    'uid-sb', DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600),
                'token_type': 'bearer',
                'refresh_token': 'r',
                'expires_in': 3600,
                'user': {'id': 'uid-sb', 'email': 'sb@example.com'},
              }),
              200);
        })));
    await client.auth
        .signInWithPassword(email: 'sb@example.com', password: 'synthetic');
    final baseline = requests;
    settingsReads = 0;

    var denied = true;
    final sub = debugStartSenderBankMappingSync(db, client,
        egressDenied: () => denied);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(settingsReads, 0, reason: 'the initial sync is skipped');

    for (final event in [
      AuthChangeEvent.initialSession,
      AuthChangeEvent.signedIn,
      AuthChangeEvent.tokenRefreshed,
      AuthChangeEvent.userUpdated,
    ]) {
      client.auth.notifyAllSubscribers(event);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(settingsReads, 0, reason: 'no consent read, hence no sync');
    expect(requests, baseline, reason: 'no remote call');

    // Control: the very same listener syncs once local read is over.
    denied = false;
    client.auth.notifyAllSubscribers(AuthChangeEvent.tokenRefreshed);
    await positiveRead.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(settingsReads, greaterThan(0),
        reason: 'the listener is alive; only the guard held it back');
  });
}
