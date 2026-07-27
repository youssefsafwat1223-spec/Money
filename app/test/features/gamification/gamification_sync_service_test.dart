import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_gamification_repository.dart';
import 'package:money_companion/features/gamification/services/gamification_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

http.Response _json(Object body, http.BaseRequest request, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
    request: request,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial remote bootstrap creates missing streak when XP exists',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);

    var streakExists = false;
    var streakUpserts = 0;
    var xpUpserts = 0;
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        final table = request.url.pathSegments.last;
        final select = request.url.queryParameters['select'];

        if (request.method == 'POST') {
          if (table == 'user_streaks') {
            streakExists = true;
            streakUpserts++;
          }
          if (table == 'user_xp_levels') xpUpserts++;
          return _json(<Object>[], request);
        }

        switch (table) {
          case 'user_xp_levels':
            return _json([
              {'user_id': 'qa-user', 'xp': 20, 'level': 2}
            ], request);
          case 'user_streaks':
            if (!streakExists) return _json(<Object>[], request);
            return _json([
              {
                'user_id': 'qa-user',
                'current_streak': 0,
                'longest_streak': 0,
                'last_active_date': '2026-07-23T00:00:00Z',
              }
            ], request);
          case 'user_achievements':
            return _json(<Object>[], request);
          default:
            fail(
                'Unexpected request: ${request.method} ${request.url} ($select)');
        }
      }),
    );

    final service = GamificationSyncService(
      db: db,
      supabase: client,
      gamificationRepo: DriftGamificationRepository(db),
      getAuthUserId: () async => 'qa-user',
    );

    await service.performSync();
    await service.performSync();

    expect(streakUpserts, 1);
    expect(xpUpserts, 0);
  });
}
