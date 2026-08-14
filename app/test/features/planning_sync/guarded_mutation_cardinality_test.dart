// MALI-026 (Phase-9M) — behavioral cardinality (0/1/>1) for the REAL planning +
// accounts guarded-mutation sinks, driven through a MockClient-backed
// Supabase.instance. 0 rows → null (conflict branch); 1 row → the ACK; >1 rows →
// GuardedMutationCardinalityError (invariant, never a conflict). No English
// PGRST116 wording anywhere — the mock models [] / [row] / [row1,row2].
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/guarded_mutation.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

List<Map<String, dynamic>> rows = const [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final msg =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    msg.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.app_links/messages'),
        (c) async => null);
    msg.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (c) async => null);
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'anon',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((req) async => http.Response(jsonEncode(rows), 200,
          headers: const {'content-type': 'application/json'}, request: req)),
    );
  });

  const planning = SupabasePlanningRemoteSink();
  const accounts = SupabaseAccountsRemoteSink();

  Future<void> triple(Future<Map<String, dynamic>?> Function() call) async {
    rows = const [];
    expect(await call(), isNull, reason: '0 rows → null (conflict branch)');
    rows = [
      {'id': 'sid', 'updated_at': 't2', 'revision': 6}
    ];
    expect((await call())?['revision'], 6, reason: '1 row → ACK');
    rows = [
      {'id': 'a'},
      {'id': 'b'}
    ];
    expect(call, throwsA(isA<GuardedMutationCardinalityError>()),
        reason: '>1 rows → invariant violation, never a conflict');
  }

  group('planning sink', () {
    test(
        'casUpdateByServerId 0/1/>1',
        () => triple(
            () => planning.casUpdateByServerId('user_goals', 'sid', 5, {})));
    test('casTombstone 0/1/>1',
        () => triple(() => planning.casTombstone('user_goals', 'sid', 5)));
    test(
        'guardedTombstone (updated_at) 0/1/>1',
        () => triple(
            () => planning.guardedTombstone('user_goals', 'sid', 'base')));
    test(
        'guardedTombstone (deleted_at null) 0/1/>1',
        () =>
            triple(() => planning.guardedTombstone('user_goals', 'sid', null)));
    test('updateByServerId (OFF guarded) 0/1/>1',
        () => triple(() => planning.updateByServerId('user_goals', 'sid', {})));
  });

  group('accounts sink', () {
    test('casUpdateAccount 0/1/>1',
        () => triple(() => accounts.casUpdateAccount('sid', 5, {})));
    test('casTombstoneAccount 0/1/>1',
        () => triple(() => accounts.casTombstoneAccount('sid', 5)));
    test('guardedTombstoneAccount 0/1/>1',
        () => triple(() => accounts.guardedTombstoneAccount('sid', 'base')));
    test('updateAccountByServerId (OFF guarded) 0/1/>1',
        () => triple(() => accounts.updateAccountByServerId('sid', {})));
  });
}
