import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_remove_barrier.dart';
import 'recording_secure_storage.dart';

// F2 — shared fixture for the Remove-data admission suites: the real session
// singleton over a real (strict) replica store and scope host, a recording
// secure storage and a fake native barrier. Every effect is recorded as an
// ATTEMPT, so a recreation that a later step deletes again is still caught.

const kMarkerKey = 'local_data_owner_uid';
const kGenerationKey = 'local_data_owner_generation';

class _Crash implements Exception {}

/// Delegates to the real host; lets a test hold a call open after it ran.
class GatedScope implements AccountScopeControl {
  GatedScope(this.host);
  final AccountScopeHost host;

  @override
  String? get activeUid => host.activeUid;

  /// Completes (once) when the first `detach` finished its work, i.e. when the
  /// signed-out scope is published and a generation-keyed ProviderScope remounts.
  Hold? holdAfterDetach;
  final List<String> calls = [];

  @override
  Future<void> activate(String uid, {AdmissionAuthority? authority}) {
    calls.add('activate:$uid');
    return host.activate(uid, authority: authority);
  }

  @override
  Future<void> lock() {
    calls.add('lock');
    return host.lock();
  }

  @override
  Future<void> suspendForSwap() => host.suspendForSwap();

  @override
  Future<void> detach() async {
    calls.add('detach');
    await host.detach();
    final hold = holdAfterDetach;
    if (hold != null && !hold.used) {
      hold.used = true;
      hold.reached.complete();
      await hold.release.future;
    }
  }
}

class F2Fixture {
  F2Fixture._();

  final session = AppSession.instance;
  late Directory support;
  late RecordingSecureStorage storage;
  late ReplicaStore store;
  late AccountScopeHost host;
  late GatedScope scope;
  late RemoveDataFlow flow;
  late FakeRemoveBarrier barrier;
  late List<String> order;
  Future<AccountScopeInit> Function(AppDatabase db, String? uid)? initialize;
  Future<void> Function()? afterWithdraw;
  ReplicaOpener? opener;
  String? crashAfterStep;

  /// [afterWithdraw] defaults to the host's own; the widget test passes
  /// production's `WidgetsBinding.instance.endOfFrame`.
  static Future<F2Fixture> create({
    Future<AccountScopeInit> Function(AppDatabase db, String? uid)? initialize,
    Future<void> Function()? afterWithdraw,
    ReplicaOpener? opener,
  }) async {
    final f = F2Fixture._();
    f.initialize = initialize;
    f.afterWithdraw = afterWithdraw;
    f.opener = opener;
    f.support = Directory.systemTemp.createTempSync('f2_fixture_');
    f.storage = RecordingSecureStorage().install();
    f.order = [];
    f.barrier = FakeRemoveBarrier(f.order);
    f.session.configureCaptureOwnerClear(() async => true);
    await f.session.wipeAndReset();
    f._build();
    return f;
  }

  /// A NEW process: new store, host, scope and flow over the SAME persisted
  /// secure storage, file system and native barrier; the session reloads its
  /// persisted state. Nothing in memory of the previous instances survives.
  Future<void> restart() async {
    await host.lock();
    host.dispose();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    _build();
    await session.load();
  }

  void _build() {
    store = ReplicaStore(appSupportDirectory: support.path, opener: opener);
    host = AccountScopeHost(
      store: store,
      initialize: (db, uid) async => await (initialize?.call(db, uid) ??
          Future.value(const AccountScopeInit())),
      afterWithdraw: afterWithdraw,
    );
    scope = GatedScope(host);
    flow = RemoveDataFlow(
      store: store,
      scope: scope,
      barrier: barrier,
      clearOwnerMarker: session.clearLocalDataOwnerMarker,
      quiesce: session.drainAdmissions,
      invalidateAdmissionGeneration: session.invalidateRemovalGeneration,
      debugAfterStep: (s) async {
        if (s == crashAfterStep) throw _Crash();
      },
    );
    session.configureAccountScope(scope);
    session.configureRemoveData(flow);
  }

  Future<void> dispose() async {
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureCaptureOwnerClear(null);
    await host.lock();
    host.dispose();
    await session.wipeAndReset();
    session.debugResetAdmissionState();
    support.deleteSync(recursive: true);
  }

  /// An explicit, successful sign-in of [uid] (the only thing that may create).
  Future<void> signIn(String uid) => session.completeOnboarding(
      method: 'google', email: '$uid@example.com', userId: uid);

  Future<String> hash(String uid) => store.uidHash(uid);

  Directory replicaDir(String hash) =>
      Directory(p.join(support.path, 'replicas', hash));

  Future<bool> keyPresent(String uid) async =>
      storage.data.containsKey('qirsh.db_key.${await hash(uid)}');

  Future<ReplicaEntry?> registryEntry(String uid) async {
    final h = await hash(uid);
    for (final e in await store.list()) {
      if (e.uidHash == h) return e;
    }
    return null;
  }

  /// Everything a recreation of [uid]'s replica would touch.
  Future<List<String>> artifactsOf(String uid) async {
    final h = await hash(uid);
    return [
      if (replicaDir(h).existsSync()) 'dir',
      if (storage.data.containsKey('qirsh.db_key.$h')) 'key',
      if (await registryEntry(uid) != null) 'registry',
    ];
  }

  /// A client whose fake GoTrue endpoints answer for [uid], so a test can make
  /// the SDK emit the REAL events (`signedIn` via recoverSession, `tokenRefreshed`
  /// via refreshSession, `userUpdated` via updateUser) without any network.
  SupabaseClient client([String uid = 'uid-none']) => fakeClient(uid);

  static SupabaseClient fakeClient([String uid = 'uid-none']) => SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          final user = _userJson(uid);
          if (request.url.path.endsWith('/token')) {
            return Response(
                jsonEncode({
                  'access_token': _jwt(uid),
                  'token_type': 'bearer',
                  'expires_in': 3600,
                  'refresh_token': 'refresh-$uid',
                  'user': user,
                }),
                200,
                headers: {'content-type': 'application/json'});
          }
          if (request.url.path.endsWith('/user')) {
            return Response(jsonEncode(user), 200,
                headers: {'content-type': 'application/json'});
          }
          return Response('{}', 200);
        }),
      );

  static Map<String, dynamic> _userJson(String uid) => {
        'id': uid,
        'aud': 'authenticated',
        'email': '$uid@example.com',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'created_at': '2026-10-01T00:00:00Z',
      };

  static String _jwt(String uid) {
    String segment(Map<String, dynamic> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    return '${segment({'alg': 'none', 'typ': 'JWT'})}.'
        '${segment({
          'exp': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
          'sub': uid,
        })}.';
  }

  Future<SupabaseClient> clientFor(String uid) => liveClient(uid);

  /// A client holding a live (fake) session for [uid].
  static Future<SupabaseClient> liveClient(String uid) async {
    final c = fakeClient(uid);
    await recoverSession_(c, uid);
    return c;
  }

  Future<void> recoverSession(SupabaseClient c, String uid) =>
      F2Fixture.recoverSession_(c, uid);

  static Future<void> recoverSession_(SupabaseClient c, String uid) async {
    await c.auth.recoverSession(jsonEncode({
      'access_token': _jwt(uid),
      'token_type': 'bearer',
      'refresh_token': 'refresh-$uid',
      'user': _userJson(uid),
    }));
  }
}
