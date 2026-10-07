import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/catalog_sync_service.dart';
import 'package:money_companion/data/catalog/feature_flag_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Astra H2.4: cached or local safety state never becomes MORE permissive
/// because remote state is missing, malformed or stale.
void main() {
  late AppDatabase db;
  late RemoteFeatureFlagsDao flags;
  Object? body;

  CatalogSyncService service() => CatalogSyncService(
        database: db,
        client: SupabaseClient('https://example.supabase.co', 'anon',
            httpClient: MockClient((req) async => http.Response(
                jsonEncode(body), 200,
                headers: const {'content-type': 'application/json'}))),
        metadataDao: CatalogMetadataDao(db),
        announcementService:
            AnnouncementService(dao: RemoteAnnouncementsDao(db)),
      );

  // enable_goals defaults to TRUE; a cached remote value of false is a disabled
  // switch that must survive.
  Future<void> seedDisabled() => flags.replaceAll([
        RemoteFeatureFlag(
            key: 'enable_goals',
            valueType: 'boolean',
            value: 'false',
            rolloutPercent: 100,
            targetCountries: const [],
            isActive: true,
            syncedAt: DateTime.utc(2026, 1, 1)),
      ]);

  Future<bool> goalsEnabled() async {
    final s = FeatureFlagService(dao: flags, installId: 'i');
    await s.init();
    return s.getBool('enable_goals');
  }

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    flags = RemoteFeatureFlagsDao(db);
    await seedDisabled();
  });
  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
  });

  test('precondition: the cached disabled switch is honoured', () async {
    expect(await goalsEnabled(), isFalse);
  });

  for (final malformed in <Object?>[
    <String, Object?>{},
    <String, Object?>{'error': 'upstream'},
    <String, Object?>{'flags': 'nope'},
    null,
    'oops',
  ]) {
    test(
        'catalog-flags answering ${jsonEncode(malformed)} keeps the cached '
        'disabled switch (previously: cache wiped, default true)', () async {
      body = malformed;
      await service().syncFlags();
      expect(await goalsEnabled(), isFalse);
    });
  }

  test('control: an authoritative snapshot still replaces the cache', () async {
    body = {'flags': <Object>[]};
    await service().syncFlags();
    expect(await goalsEnabled(), isTrue,
        reason: 'a well-formed (empty) snapshot is the server\'s decision');
    body = {
      'flags': [
        {
          'key': 'enable_goals',
          'value_type': 'boolean',
          'value': 'false',
          'rollout_percent': 100,
          'is_active': true,
        }
      ]
    };
    await service().syncFlags();
    expect(await goalsEnabled(), isFalse);
  });

  test('a malformed announcements envelope keeps a cached force-update',
      () async {
    final dao = RemoteAnnouncementsDao(db);
    await dao.replaceAll([
      RemoteAnnouncement(
          id: 'a1',
          titleAr: 't',
          titleEn: 't',
          bodyAr: null,
          bodyEn: null,
          severity: 'force_update',
          minAppVersion: null,
          maxAppVersion: null,
          actionLabelAr: null,
          actionLabelEn: null,
          actionUrl: null,
          validFrom: DateTime.utc(2020),
          validUntil: null,
          isDismissible: false,
          priority: 1,
          isDismissed: false,
          dismissedAt: null,
          syncedAt: DateTime.utc(2026)),
    ]);
    body = <String, Object?>{'oops': true};
    await service().syncAnnouncements();
    expect(await AnnouncementService(dao: dao).hasForceUpdate(), isTrue);
  });

  test(
      'a failed flag RELOAD keeps the last good instance instead of '
      'regressing to the bare defaults', () async {
    final first = await initFeatureFlagService(db, installIdOverride: 'i');
    expect(first.getBool('enable_goals'), isFalse);
    await db.close(); // every later read now fails
    // debugPrintStack of the swallowed failure meets package:stack_trace frames.
    final demangle = FlutterError.demangleStackTrace;
    FlutterError.demangleStackTrace = (s) => StackTrace.fromString(s
        .toString()
        .split('\n')
        .where((l) => !l.startsWith('====='))
        .join('\n'));
    addTearDown(() => FlutterError.demangleStackTrace = demangle);
    final second = await initFeatureFlagService(db, installIdOverride: 'i');
    expect(identical(first, second), isTrue);
    expect(featureFlags.getBool('enable_goals'), isFalse);
  });
}
