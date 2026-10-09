import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/catalog/catalog_sync_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'f2_fixture.dart';

class _Local implements CatalogLocalWork {
  _Local(this.fixture, this.authority);
  final F2Fixture fixture;
  final AdmissionAuthority authority;
  int dispatched = 0;
  @override
  bool get current => authority.isCurrent;
  @override
  Future<T> local<T>(Future<T> Function() action) {
    authority.requireCurrent();
    dispatched++;
    return fixture.session.runAdmittedLocalOperation(authority, action);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'paused catalog network does not block removal and late response cannot apply to old database',
      () async {
    final f = await F2Fixture.create();
    addTearDown(f.dispose);
    await f.signIn('uid-x');
    final db = f.host.current!.database;
    final authority = f.session.captureLocalWorkAuthority()!;
    final work = _Local(f, authority);
    final reached = Completer<void>();
    final response = Completer<Response>();
    final client = SupabaseClient('https://example.supabase.co', 'public-anon',
        httpClient: MockClient((request) {
      reached.complete();
      return response.future;
    }));
    addTearDown(client.dispose);
    final service = CatalogSyncService(
        database: db,
        client: client,
        metadataDao: CatalogMetadataDao(db),
        announcementService:
            AnnouncementService(dao: RemoteAnnouncementsDao(db)));
    final syncing = service.syncFlags(localWork: work);
    await reached.future;
    await f.session.removeDataFromDevice().timeout(const Duration(seconds: 5));
    expect(response.isCompleted, isFalse,
        reason: 'network is outside the local drain');
    expect(work.dispatched, 0);
    response.complete(Response(
        jsonEncode({
          'flags': [
            {
              'key': 'enable_goals',
              'value_type': 'boolean',
              'value': 'false',
              'rollout_percent': 100,
              'is_active': true,
              'updated_at': '2026-10-01T00:00:00Z'
            }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'}));
    await syncing;
    expect(work.dispatched, 0,
        reason: 'late payload cannot start the DAO replace transaction');
    expect(await f.artifactsOf('uid-x'), isEmpty);
  });
}
