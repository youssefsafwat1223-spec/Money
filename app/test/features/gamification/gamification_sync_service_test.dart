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

// MALI-024 — the client is PULL-ONLY for gamification aggregates. It must never
// upload an XP/streak/achievement total (the old dual-authority tamper vector).

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

  test('performSync pulls the server aggregate and NEVER uploads a total',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);

    final aggregateWrites = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        final table = request.url.pathSegments.last;
        // Any write to an aggregate table is the tamper vector — record it so
        // the test fails if the client ever uploads a total again.
        if (request.method == 'POST' ||
            request.method == 'PATCH' ||
            request.method == 'PUT') {
          aggregateWrites.add('${request.method} $table');
          return _json(<Object>[], request);
        }
        switch (table) {
          case 'user_xp_levels':
            return _json([
              {'user_id': 'qa-user', 'xp': 20, 'level': 2}
            ], request);
          case 'user_streaks':
            return _json([
              {
                'user_id': 'qa-user',
                'current_streak': 3,
                'longest_streak': 5,
                'last_active_date': '2026-07-23T00:00:00Z',
              }
            ], request);
          case 'user_achievements':
            return _json(<Object>[], request);
          default:
            fail('Unexpected request: ${request.method} ${request.url}');
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

    // The client uploaded NOTHING — no arbitrary XP/streak/achievement total.
    expect(aggregateWrites, isEmpty,
        reason: 'the client must never upload a gamification total');

    // The acknowledged server aggregate is mirrored locally.
    final xp = (await db
            .customSelect('SELECT total_xp, level FROM xp_levels LIMIT 1;')
            .getSingle());
    expect(xp.read<int>('total_xp'), 20);
    expect(xp.read<int>('level'), 2);
  });
}
