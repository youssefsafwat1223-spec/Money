// WP-5: the revision_cas capability (kill switch) and the CAS gate that turns
// it, plus the replica epoch, into one decision per push cycle.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/fake_cas_server.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late DateTime now;
  late int calls;
  late http.Response Function(http.Request) reply;

  ServerCapabilitiesService svc() => ServerCapabilitiesService(
        getAuthUserId: () async => 'u1',
        getClient: () => SupabaseClient(
          'https://example.supabase.co',
          'anon',
          accessToken: () async => 't',
          httpClient: MockClient((r) async {
            calls++;
            return reply(r);
          }),
        ),
        mayEgress: () async => true,
        getServerUrl: () => 'https://example.supabase.co',
        clock: () => now,
      );

  http.Response Function(http.Request) ok(Map<String, Object?> body) =>
      (r) => http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'}, request: r);

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
    calls = 0;
  });

  group('revision_cas capability', () {
    test('false (production) is unsupported; true is verified; it is '
        'independent of sync_seq', () async {
      reply = ok({'sync_seq': true, 'revision_cas': false});
      final s = svc();
      expect(await s.revisionCas(), ServerCapabilityState.unsupported);
      expect(await s.syncSeq(), ServerCapabilityState.verified);
      reply = ok({'revision_cas': true});
      now = now.add(const Duration(minutes: 16));
      expect(await s.revisionCas(), ServerCapabilityState.verified);
    });

    test('cached, then re-probed after the TTL: withdrawing it returns the '
        'client to legacy', () async {
      reply = ok({'revision_cas': true});
      final s = svc();
      expect(await s.revisionCas(), ServerCapabilityState.verified);
      expect(await s.revisionCas(), ServerCapabilityState.verified);
      expect(calls, 1);
      reply = ok({'revision_cas': false});
      now = now.add(ServerCapabilitiesService.syncSeqTtl + const Duration(seconds: 1));
      expect(await s.revisionCas(), ServerCapabilityState.unsupported);
    });

    test('an error is unknown, never "absent"', () async {
      reply = (r) => http.Response('boom', 503, request: r);
      expect(await svc().revisionCas(), ServerCapabilityState.unknown);
    });
  });

  group('CasResult / gate', () {
    test('parses every WP-2 outcome and rejects an unknown one', () {
      for (final (name, outcome) in [
        ('inserted', CasOutcome.inserted),
        ('adopted', CasOutcome.adopted),
        ('ack', CasOutcome.ack),
        ('applied', CasOutcome.applied),
        ('conflict', CasOutcome.conflict),
        ('not_found', CasOutcome.notFound),
        ('epoch_mismatch', CasOutcome.epochMismatch),
      ]) {
        expect(CasResult.fromJson({'outcome': name, 'row': null}).outcome, outcome);
      }
      expect(CasResult.fromJson({'outcome': 'conflict', 'row': null, 'reason': 'unique_violation'}).reason,
          'unique_violation');
      expect(() => CasResult.fromJson({'outcome': 'bogus'}), throwsFormatException);
    });

    test('plan: unsupported → legacy, unknown → stopped, verified → cas with '
        'the RECORDED epoch (else the head epoch)', () async {
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      expect((await casGate(db, capability: ServerCapabilityState.unsupported).plan('u1')).mode,
          CasMode.legacy);
      expect((await casGate(db, capability: ServerCapabilityState.unknown).plan('u1')).mode,
          CasMode.stopped);
      expect((await casGate(db, epoch: 'head-e').plan('u1')).epoch, 'head-e');
      await writeRecordedSyncEpoch(db, 'u1', 'recorded-e', null);
      final p = await casGate(db, epoch: 'head-e').plan('u1');
      expect(p.isCas, isTrue);
      expect(p.epoch, 'recorded-e',
          reason: 'a stale replica must present ITS epoch so the server can refuse it');
    });
  });
}
