import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:money_companion/core/auth/prepared_immediate_deletion_gateway.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import '../session/f2_fixture.dart';

const _bound = Duration(seconds: 5);
const _owner = 'prepared-owner-a';
final _url = Uri.parse(
    'https://example.supabase.co/functions/v1/delete-account-immediate');
Future<T> _bounded<T>(Future<T> work) => work.timeout(_bound);
http.Response _reply(String status, [int code = 200]) =>
    http.Response(jsonEncode({'status': status}), code,
        headers: {'content-type': 'application/json'});

class _Memory {
  final values = <String, String>{};
  final events = <String>[];
  Future<void> Function(String key)? beforeRead;
  Future<void> Function(ImmediateDeletionReceipt record)? beforeWrite;
  ImmediateDeletionReceipt? lastWrite;
  late final store = ImmediateDeletionReceiptStore(
    authority: Object(),
    read: (key) async {
      await beforeRead?.call(key);
      final value = values[key];
      events.add(value == null
          ? 'read:absent'
          : 'read:${(jsonDecode(value) as Map)['phase']}');
      return value;
    },
    write: (key, value) async {
      final json = jsonDecode(value) as Map;
      final record = ImmediateDeletionReceipt(
          owner: json['owner'] as String,
          operationId: json['operation_id'] as String,
          receiptSecret: json['receipt_secret'] as String?,
          phase: ImmediateDeletionPhase.values.byName(json['phase'] as String));
      await beforeWrite?.call(record);
      values[key] = value;
      lastWrite = record;
      events.add('write:${record.phase.name}');
    },
    delete: (key) async {
      values.remove(key);
      events.add('delete');
    },
  );
  Future<ImmediateDeletionReceipt?> load([String owner = _owner]) =>
      store.load(owner);
}

/// Real strict host + real GoTrue client. Only transport and persistence are
/// controlled; no authority/currentness proof is fabricated by the fixture.
class _World {
  final session = AppSession.instance;
  final memory = _Memory();
  final requests = <http.Request>[];
  final unexpected = <http.Request>[];
  final unexpectedSdk = <http.Request>[];
  final gateways = <PreparedImmediateDeletionGateway>[];
  final releases = <Completer<void>>[];
  final producers = <Future<void>>[];
  final failures = <(Object, StackTrace)>[];
  final databases = <AppDatabase>[];
  final oldGate = CloudEgressGate.instance;
  final egress = TestEgress();
  late F2Fixture fixture;
  late SupabaseClient sdk;
  late MockClient transport;
  late void Function() restoreFence;
  bool bound = false;
  bool fixtureCreated = false;
  bool sdkCreated = false;
  bool transportCreated = false;
  bool fenceInstalled = false;
  Future<http.Response> Function(http.Request) answer =
      (_) async => _reply('accepted', 202);

  static Future<_World> open({bool admitted = true}) async {
    final h = _World();
    try {
      await h.session.debugResetAuthBinding();
      h.session.configureAccountScope(null);
      await h.session.drainAdmissions();
      h.restoreFence = AccountFenceAuthority.replacePersistenceForTest();
      h.fenceInstalled = true;
      h.fixture = await F2Fixture.create(afterWithdraw: () async {});
      h.fixtureCreated = true;
      h.session.configureAccountScope(h.fixture.host);
      void remember() {
        final db = h.fixture.host.current?.database;
        if (db != null && !h.databases.contains(db)) {
          h.databases.add(db);
        }
      }

      h.fixture.host.addListener(remember);
      remember();
      h.sdk = SupabaseClient('https://example.supabase.co', 'synthetic-anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          // Gated like production: a local sign-out's logout request is denied
          // with Cloud OFF and never reaches the socket.
          httpClient: GatedHttpClient(MockClient((request) async {
        // A recovered, unexpired SDK session needs no transport here. Any
        // refresh/user/network request is a separately recorded fixture error.
        h.unexpectedSdk.add(request);
        throw StateError('unexpected SDK transport');
      })));
      h.sdkCreated = true;
      await F2Fixture.recoverSession_(h.sdk, _owner);
      h.transport = MockClient((request) async {
        h.requests.add(request); // Outside all adapter/recovery catches.
        final Object? body;
        try {
          body = jsonDecode(request.body);
        } on FormatException {
          h.unexpected.add(request);
          throw StateError('unexpected non-JSON deletion request');
        }
        final status = body is Map && body['action'] == 'status';
        final valid = request.method == 'POST' &&
            request.url == _url &&
            body is Map &&
            body['receipt_secret'] is String &&
            RegExp(r'^[A-Za-z0-9_-]{43,128}$')
                .hasMatch(body['receipt_secret'] as String) &&
            (status
                ? body.length == 2 &&
                    !request.headers.containsKey('Authorization')
                : body.length == 3 &&
                    body['challenge_id'] == 'synthetic-challenge' &&
                    body['challenge_response'] == 'synthetic-external-proof' &&
                    request.headers['Authorization'] ==
                        'Bearer ${h.sdk.auth.currentSession?.accessToken}');
        if (!valid) {
          h.unexpected.add(request);
          throw StateError('unexpected deletion transport');
        }
        h.memory.events.add('http');
        return h.answer(request);
      });
      h.transportCreated = true;
      h.egress.owner = _owner;
      h.egress.install();
      if (admitted) {
        await h.admit();
      }
      return h;
    } catch (_) {
      await h.finish();
      rethrow;
    }
  }

  Future<void> admit() async {
    final actual = sdk.auth.currentSession!;
    await session.setIdentity(
        method: 'google',
        email: actual.user.email,
        userId: actual.user.id,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken &&
            sdk.auth.currentSession?.isExpired == false);
    await session.finishOnboarding(client: sdk);
    if (!bound) {
      final event = Completer<void>();
      session.debugAuthEventCompleted = (type) {
        if (type == AuthChangeEvent.tokenRefreshed && !event.isCompleted) {
          event.complete();
        }
      };
      try {
        await session.bindSupabaseAuth(sdk);
        await _bounded(event.future);
      } finally {
        session.debugAuthEventCompleted = null;
      }
      bound = true;
    } else {
      await session.bindSupabaseAuth(sdk);
    }
    expect(session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
    expect(session.captureCallbackOrigin()?.isCurrent, isTrue);
  }

  Future<void> switchTo(String next) async {
    final event = Completer<void>();
    session.debugAuthEventCompleted = (type) {
      if (type == AuthChangeEvent.tokenRefreshed && !event.isCompleted) {
        event.complete();
      }
    };
    try {
      await F2Fixture.recoverSession_(sdk, next);
      await _bounded(event.future);
    } finally {
      session.debugAuthEventCompleted = null;
    }
    egress.owner = next;
    await admit();
  }

  PreparedImmediateDeletionGateway gateway() {
    final gateway = PreparedImmediateDeletionGateway(
        session: session,
        host: fixture.host,
        client: sdk,
        store: memory.store,
        transport: transport,
        functionUrl: _url,
        gate: egress.gate,
        requestTimeout: const Duration(seconds: 2));
    gateways.add(gateway);
    return gateway;
  }

  Future<T> track<T>(Future<T> future) {
    producers.add(
        future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      failures.add((error, stack));
    }));
    return future;
  }

  Completer<void> hold() {
    final release = Completer<void>();
    releases.add(release);
    return release;
  }

  Future<PreparedDeletionOutcome> request(
          PreparedImmediateDeletionGateway gateway,
          PreparedDeletionOperation operation) =>
      track(gateway.request(operation,
          challengeId: 'synthetic-challenge',
          challengeResponse: 'synthetic-external-proof'));

  Future<void> finish() async {
    for (final release in releases) {
      if (!release.isCompleted) {
        release.complete();
      }
    }
    Object? cleanupError;
    StackTrace? cleanupStack;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await _bounded(action());
      } catch (error, stack) {
        cleanupError ??= error;
        cleanupStack ??= stack;
      }
    }

    await cleanup(() async {
      await Future.wait(producers);
    });
    for (final gateway in gateways) {
      await cleanup(gateway.waitPendingWork);
    }
    session.debugAuthEventCompleted = null;
    await cleanup(session.debugResetAuthBinding);
    await cleanup(session.drainAdmissions);
    if (fixtureCreated) {
      await cleanup(fixture.dispose);
    }
    if (sdkCreated) {
      await cleanup(sdk.dispose);
    }
    if (transportCreated) {
      transport.close();
    }
    CloudEgressGate.instance = oldGate;
    if (cleanupError == null && fenceInstalled) {
      restoreFence();
      fenceInstalled = false;
    }
    expect(unexpected, isEmpty,
        reason: 'no unknown request hidden by service catches');
    expect(unexpectedSdk, isEmpty,
        reason: 'no real SDK network/refresh was needed');
    for (final db in databases) {
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStack!);
    }
    if (failures.isNotEmpty) {
      Error.throwWithStackTrace(failures.first.$1, failures.first.$2);
    }
  }
}

Future<void> _world(Future<void> Function(_World) test,
    {bool admitted = true}) async {
  final h = await _World.open(admitted: admitted);
  try {
    await test(h);
  } finally {
    await h.finish();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'construction is inert; matched original operation alone yields remote evidence',
      () => _world((h) async {
            final before = h.fixture.storage.attempts.length;
            final host = h.fixture.host.current;
            final capability = h.session.captureConsentCapability();
            final gateway = h.gateway();
            expect(h.memory.events, isEmpty);
            expect(h.requests, isEmpty);
            expect(h.fixture.storage.attempts.length, before);
            final operation = (await _bounded(gateway.prepare()))!;
            expect(h.memory.events, ['read:absent']);
            expect(h.requests, isEmpty);
            h.answer = (_) async => _reply('completed');
            final result = await _bounded(h.request(gateway, operation));
            expect(result, isA<PreparedDeletionRemoteCompletion>());
            expect(
                identical(
                    (result as PreparedDeletionRemoteCompletion).operation,
                    operation),
                isTrue);
            final record = (await h.memory.load())!;
            expect(record.phase, ImmediateDeletionPhase.completed);
            expect(record.receiptSecret, isNull);
            expect(h.requests, hasLength(1));
            final wire = jsonDecode(h.requests.single.body) as Map;
            final httpAt = h.memory.events.indexOf('http');
            for (final phase in ['created', 'mayHaveBeenSent']) {
              final writeAt = h.memory.events.indexOf('write:$phase');
              final readAt = h.memory.events.indexOf('read:$phase', writeAt);
              expect(writeAt, isNonNegative);
              expect(readAt, greaterThan(writeAt));
              expect(httpAt, greaterThan(readAt));
            }
            expect(h.fixture.host.current, same(host));
            expect(h.session.captureConsentCapability(), same(capability));
            expect(h.session.status, SessionStatus.authenticated);
            expect(h.fixture.storage.attempts.length, before,
                reason:
                    'the adapter never resets/signs out or changes session/consent storage');
            expect('$operation $result',
                isNot(contains(wire['receipt_secret'] as String)));
            expect('$operation $result',
                isNot(contains(h.sdk.auth.currentSession!.accessToken)));
            expect(await h.request(gateway, operation),
                isA<PreparedDeletionUnconfirmed>());
            expect(h.requests, hasLength(1),
                reason: 'evidence closes, never reauthorizes');
          }));

  test(
      'preparation without original admission never revives after real admission',
      () => _world((h) async {
            final gateway = h.gateway();
            final initial = gateway.prepare();
            await h.admit();
            expect(await _bounded(initial), isNull);
            expect(h.memory.events, isEmpty);
            expect(h.requests, isEmpty);
            expect(await _bounded(gateway.prepare()), isNotNull,
                reason: 'independent matched positive');
          }, admitted: false));

  for (final resume in [false, true]) {
    test(
        'held ${resume ? 'resumption' : 'preparation'} read cannot publish a successor handle',
        () => _world((h) async {
              final gateway = h.gateway();
              if (resume) {
                final first = (await _bounded(gateway.prepare()))!;
                expect(await _bounded(h.request(gateway, first)),
                    isA<PreparedDeletionPending>());
              }
              final before = Map<String, String>.from(h.memory.values);
              final requestsBefore = h.requests.length;
              final reached = Completer<void>();
              final release = h.hold();
              var held = false;
              h.memory.beforeRead = (_) async {
                if (!held) {
                  held = true;
                  reached.complete();
                  await release.future;
                }
              };
              final preparing =
                  h.track(resume ? gateway.resumePending() : gateway.prepare());
              await _bounded(reached.future);
              await h.admit(); // A genuine new admission of the SAME UID.
              release.complete();
              expect(await _bounded(preparing), isNull);
              expect(h.requests, hasLength(requestsBefore));
              expect(h.memory.values, before);
              final fresh = await _bounded(
                  resume ? gateway.resumePending() : gateway.prepare());
              expect(fresh, isNotNull,
                  reason: 'unchanged original preparation is admitted');
            }));
  }

  for (final sameUid in [true, false]) {
    test(
        'held challenge continuation loses original ${sameUid ? 'same-UID' : 'other-owner'} lifetime',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              final reached = Completer<void>();
              final release = h.hold();
              final continuing = h.track(() async {
                reached.complete();
                await release.future;
                return h.request(gateway, operation);
              }());
              await _bounded(reached.future);
              if (sameUid) {
                await h.admit();
              } else {
                await h.switchTo('prepared-owner-b');
              }
              final successor = h.fixture.host.current;
              final before = h.fixture.storage.attempts.length;
              release.complete();
              expect(await _bounded(continuing),
                  isA<PreparedDeletionUnconfirmed>());
              expect(h.requests, isEmpty);
              expect(h.memory.values, isEmpty);
              expect(h.fixture.host.current, same(successor));
              expect(h.fixture.storage.attempts.length, before);
              expect(
                  h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
              final fresh = (await _bounded(gateway.prepare()))!;
              expect(await _bounded(h.request(gateway, fresh)),
                  isA<PreparedDeletionPending>());
            }));
  }

  for (final throws in [false, true]) {
    test(
        'caller restriction ${throws ? 'throws' : 'denies'} at queue start, never grants',
        () => _world((h) async {
              final gateway = h.gateway();
              var allowed = true;
              final operation = (await _bounded(gateway.prepare(restrict: () {
                if (!allowed && throws) {
                  throw StateError('restriction');
                }
                return allowed;
              })))!;
              allowed = false;
              final running = h.request(gateway, operation);
              expect(
                  await _bounded(running), isA<PreparedDeletionUnconfirmed>());
              allowed = true;
              expect(await _bounded(h.request(gateway, operation)),
                  isA<PreparedDeletionUnconfirmed>());
              expect(h.requests, isEmpty, reason: 'loss never silently renews');
            }));
  }

  for (final stage in ['created', 'mayHaveBeenSent', 'readback']) {
    test(
        'held $stage custody precedes every HTTP byte',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              final reached = Completer<void>();
              final release = h.hold();
              var held = false;
              if (stage == 'readback') {
                h.memory.beforeRead = (_) async {
                  if (!held &&
                      h.memory.lastWrite?.phase ==
                          ImmediateDeletionPhase.mayHaveBeenSent) {
                    held = true;
                    reached.complete();
                    await release.future;
                  }
                };
              } else {
                h.memory.beforeWrite = (record) async {
                  if (!held && record.phase.name == stage) {
                    held = true;
                    reached.complete();
                    await release.future;
                  }
                };
              }
              final running = h.request(gateway, operation);
              await _bounded(reached.future);
              expect(h.requests, isEmpty);
              release.complete();
              expect(
                  await _bounded(running),
                  isA<PreparedDeletionPending>().having((state) => state.kind,
                      'accepted status', PreparedDeletionPendingKind.accepted));
              expect(h.requests, hasLength(1));
            }));
  }

  for (final stage in ['created', 'mayHaveBeenSent', 'readback']) {
    test(
        'failed $stage custody sends no HTTP',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              var failureReached = false;
              if (stage == 'readback') {
                h.memory.beforeRead = (_) async {
                  if (h.memory.lastWrite?.phase ==
                      ImmediateDeletionPhase.mayHaveBeenSent) {
                    failureReached = true;
                    throw StateError('readback');
                  }
                };
              } else {
                h.memory.beforeWrite = (record) async {
                  if (record.phase.name == stage) {
                    failureReached = true;
                    throw StateError('custody write');
                  }
                };
              }
              expect(await _bounded(h.request(gateway, operation)),
                  isA<PreparedDeletionUnconfirmed>());
              expect(failureReached, isTrue);
              expect(h.requests, isEmpty);
              h.memory.beforeRead = null;
              h.memory.beforeWrite = null;
            }));
  }

  test(
      'response loss retains exact operation; recreated adapter resumes status only',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            final reached = Completer<void>();
            final release = h.hold();
            h.answer = (_) async {
              reached.complete();
              await release.future;
              throw StateError('lost reply');
            };
            final running = h.request(gateway, operation);
            await _bounded(reached.future);
            final custody = (await h.memory.load())!;
            expect(custody.phase, ImmediateDeletionPhase.mayHaveBeenSent);
            release.complete();
            expect(await _bounded(running), isA<PreparedDeletionUnconfirmed>());
            final recreated = h.gateway();
            expect(await _bounded(recreated.prepare()), isNull,
                reason: 'explicit pending selection required');
            final resumed = (await _bounded(recreated.resumePending()))!;
            h.answer = (_) async => _reply('in_progress', 202);
            expect(
                await _bounded(h.track(recreated.recover(resumed))),
                isA<PreparedDeletionPending>().having((state) => state.kind,
                    'running status', PreparedDeletionPendingKind.inProgress));
            expect(h.requests, hasLength(2));
            expect(jsonDecode(h.requests.last.body),
                {'action': 'status', 'receipt_secret': custody.receiptSecret});
            expect(
                h.requests.last.headers.containsKey('Authorization'), isFalse);
            expect((await h.memory.load())!.encode(), custody.encode());
            h.answer = (_) async => _reply('completed');
            expect(await _bounded(h.track(recreated.recover(resumed))),
                isA<PreparedDeletionRemoteCompletion>());
            expect(h.requests, hasLength(3));
            expect(jsonDecode(h.requests.last.body)['receipt_secret'],
                custody.receiptSecret);
          }));

  http.Response refusedReply(String code, int status) => http.Response(
      jsonEncode({'status': 'error', 'code': code}), status,
      headers: {'content-type': 'application/json'});

  test('definitive reject abandons exactly this operation\'s receipt',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            h.answer = (_) async => refusedReply('challenge_expired', 400);
            final result = await _bounded(h.request(gateway, operation));
            expect(result, isA<PreparedDeletionRejected>());
            expect((result as PreparedDeletionRejected).code,
                'challenge_expired');
            expect(await h.memory.load(), isNull);
            expect(await _bounded(h.gateway().prepare()), isNotNull,
                reason: 'a new operation is allowed');
          }));

  test('reject never abandons a receipt that is no longer exactly this one',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            final key = ImmediateDeletionReceiptStore.storageKey(_owner);
            h.answer = (_) async {
              h.memory.values[key] = ImmediateDeletionReceipt(
                      owner: _owner,
                      operationId: 'replacement-operation',
                      receiptSecret: 'R' * 43,
                      phase: ImmediateDeletionPhase.mayHaveBeenSent)
                  .encode();
              return refusedReply('invalid_request', 400);
            };
            final result = await _bounded(h.request(gateway, operation));
            expect(result, isA<PreparedDeletionUnconfirmed>());
            expect((await h.memory.load())!.operationId,
                'replacement-operation');
          }));

  test('reject after the binding is lost keeps the receipt (stale)',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            h.answer = (_) async {
              h.egress.gate.advanceEpoch();
              return refusedReply('invalid_request', 400);
            };
            final result = await _bounded(h.request(gateway, operation));
            expect(result, isA<PreparedDeletionUnconfirmed>());
            expect(await h.memory.load(), isNotNull);
          }));

  test('a failed delete leaves the receipt and stays unconfirmed',
      () => _world((h) async {
            final failing = ImmediateDeletionReceiptStore(
                authority: h.memory.store.authority,
                read: (k) async => h.memory.values[k],
                write: (k, v) async => h.memory.values[k] = v,
                delete: (k) async => throw StateError('delete failed'));
            final g = PreparedImmediateDeletionGateway(
                session: h.session,
                host: h.fixture.host,
                client: h.sdk,
                store: failing,
                transport: h.transport,
                functionUrl: _url,
                gate: h.egress.gate,
                requestTimeout: const Duration(seconds: 2));
            h.gateways.add(g);
            final operation = (await _bounded(g.prepare()))!;
            h.answer = (_) async => refusedReply('invalid_request', 400);
            final result = await _bounded(h.request(g, operation));
            expect(result, isA<PreparedDeletionUnconfirmed>());
            expect((await h.memory.load())!.phase,
                ImmediateDeletionPhase.mayHaveBeenSent);
          }));

  test(
      'foreign handle and previously closed tombstone cannot create fresh evidence',
      () => _world((h) async {
            final first = h.gateway();
            final second = h.gateway();
            final operation = (await _bounded(first.prepare()))!;
            expect(await _bounded(h.request(second, operation)),
                isA<PreparedDeletionUnconfirmed>());
            expect(h.requests, isEmpty);
            h.answer = (_) async => _reply('completed');
            expect(await _bounded(h.request(first, operation)),
                isA<PreparedDeletionRemoteCompletion>());
            final bytes = Map<String, String>.from(h.memory.values);
            expect(await _bounded(second.prepare()), isNull);
            expect(await _bounded(second.resumePending()), isNull);
            expect(await _bounded(h.track(first.recover(operation))),
                isA<PreparedDeletionUnconfirmed>());
            expect(h.memory.values, bytes);
            expect(h.requests, hasLength(1));
          }));

  test(
      'two prepared handles contend for one durable operation, never reauthorize',
      () => _world((h) async {
            final first = h.gateway();
            final second = h.gateway();
            final one = (await _bounded(first.prepare()))!;
            final two = (await _bounded(second.prepare()))!;
            final reached = Completer<void>();
            final release = h.hold();
            h.answer = (_) async {
              reached.complete();
              await release.future;
              return _reply('accepted', 202);
            };
            final runningOne = h.request(first, one);
            await _bounded(reached.future);
            final runningTwo = h.request(second, two);
            final queuedRecovery = h.track(first.recover(one));
            var observed = false;
            final waiting =
                first.waitPendingWork().then((_) => observed = true);
            expect(observed, isFalse);
            expect(h.requests, hasLength(1));
            h.answer = (_) async => _reply('in_progress', 202);
            release.complete();
            expect(await _bounded(runningOne), isA<PreparedDeletionPending>());
            expect(
                await _bounded(runningTwo), isA<PreparedDeletionUnconfirmed>());
            expect(
                await _bounded(queuedRecovery), isA<PreparedDeletionPending>());
            await _bounded(waiting);
            expect(observed, isTrue);
            expect(h.requests, hasLength(2));
            expect(jsonDecode(h.requests.last.body)['action'], 'status');
          }));

  test(
      'held completed response cannot overwrite another durable operation',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            final reached = Completer<void>();
            final release = h.hold();
            h.answer = (_) async {
              reached.complete();
              await release.future;
              return _reply('completed');
            };
            final running = h.request(gateway, operation);
            await _bounded(reached.future);
            final replaced = ImmediateDeletionReceipt(
                    owner: _owner,
                    operationId: 'replacement',
                    receiptSecret: 'S' * 43,
                    phase: ImmediateDeletionPhase.mayHaveBeenSent)
                .encode();
            h.memory.values[ImmediateDeletionReceiptStore.storageKey(_owner)] =
                replaced;
            release.complete();
            expect(await _bounded(running), isA<PreparedDeletionUnconfirmed>());
            expect((await h.memory.load())!.encode(), replaced);
            expect(h.requests, hasLength(1));
          }));

  test(
      'held completed response after same-UID readmission leaves successor untouched',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            final reached = Completer<void>();
            final release = h.hold();
            h.answer = (_) async {
              reached.complete();
              await release.future;
              return _reply('completed');
            };
            final running = h.request(gateway, operation);
            await _bounded(reached.future);
            await h.admit();
            final successor = h.fixture.host.current;
            final before = h.fixture.storage.attempts.length;
            release.complete();
            expect(await _bounded(running), isA<PreparedDeletionUnconfirmed>());
            expect(h.fixture.host.current, same(successor));
            expect(h.fixture.storage.attempts.length, before);
            expect(h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
            expect((await h.memory.load())!.phase,
                ImmediateDeletionPhase.mayHaveBeenSent);
          }));

  for (final response in ['202completed', 'unknown', 'malformed']) {
    test(
        '$response never produces remote evidence',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              h.answer = (_) async => switch (response) {
                    '202completed' => _reply('completed', 202),
                    'unknown' => _reply('unknown', 404),
                    _ => http.Response('[]', 200),
                  };
              expect(await _bounded(h.request(gateway, operation)),
                  isA<PreparedDeletionUnconfirmed>());
              expect((await h.memory.load())!.phase,
                  ImmediateDeletionPhase.mayHaveBeenSent);
              await _bounded(gateway.waitPendingWork());
              expect(h.requests, hasLength(1), reason: 'no automatic polling');
            }));
  }

  test(
      'failed completion readback is not completion evidence',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            h.answer = (_) async => _reply('completed');
            var failureReached = false;
            h.memory.beforeRead = (_) async {
              if (h.memory.lastWrite?.phase ==
                  ImmediateDeletionPhase.completed) {
                failureReached = true;
                throw StateError('verify');
              }
            };
            expect(await _bounded(h.request(gateway, operation)),
                isA<PreparedDeletionUnconfirmed>());
            expect(failureReached, isTrue);
            h.memory.beforeRead = null;
            expect((await h.memory.load())!.phase,
                ImmediateDeletionPhase.completed);
            expect(await _bounded(gateway.resumePending()), isNull,
                reason: 'old closed custody is not fresh authority');
          }));

  test(
      'sanitization predecessor read failure suppresses verified completion evidence',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            h.answer = (_) async => _reply('completed');
            var completedSecretReads = 0;
            var predecessorReached = false;
            const malformed = '{invalid-sanitization-predecessor';
            h.memory.beforeRead = (key) async {
              final last = h.memory.lastWrite;
              if (last?.phase == ImmediateDeletionPhase.completed &&
                  last?.receiptSecret != null) {
                completedSecretReads++;
                // The first read is the base store's successful completion readback.
                // The next read is the observer's sanitizer predecessor inspection.
                if (completedSecretReads == 2) {
                  predecessorReached = true;
                  h.memory.values[key] = malformed;
                }
              }
            };
            try {
              final result = await _bounded(h.request(gateway, operation));
              expect(predecessorReached, isTrue);
              expect(completedSecretReads, 2);
              expect(
                  h.memory
                      .values[ImmediateDeletionReceiptStore.storageKey(_owner)],
                  malformed,
                  reason: 'the failed inspection must not replace custody');
              expect(h.requests, hasLength(1));
              expect(result, isA<PreparedDeletionUnconfirmed>());
            } finally {
              h.memory.beforeRead = null;
            }
          }));

  for (final replaced in [false, true]) {
    test(
        'sanitization ${replaced ? 'mismatch irrevocably suppresses' : 'write failure alone retains verified'} evidence',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              h.answer = (_) async => _reply('completed');
              var sanitationReached = false;
              h.memory.beforeWrite = (record) async {
                if (record.phase == ImmediateDeletionPhase.completed &&
                    record.receiptSecret == null) {
                  sanitationReached = true;
                  if (replaced) {
                    h.memory.values[
                            ImmediateDeletionReceiptStore.storageKey(_owner)] =
                        ImmediateDeletionReceipt(
                                owner: _owner,
                                operationId: 'replacement',
                                receiptSecret: 'S' * 43,
                                phase: ImmediateDeletionPhase.completed)
                            .encode();
                  }
                  throw StateError('sanitization failed');
                }
              };
              final result = await _bounded(h.request(gateway, operation));
              expect(sanitationReached, isTrue);
              expect(
                  result,
                  replaced
                      ? isA<PreparedDeletionUnconfirmed>()
                      : isA<PreparedDeletionRemoteCompletion>());
              expect((await h.memory.load())!.operationId,
                  replaced ? 'replacement' : isNot('replacement'));
              expect((await h.memory.load())!.receiptSecret, isNotNull);
            }));
  }

  test(
      'close after dispatch stops delivery but preserves verified completed custody',
      () => _world((h) async {
            final gateway = h.gateway();
            final operation = (await _bounded(gateway.prepare()))!;
            final reached = Completer<void>();
            final release = h.hold();
            h.answer = (_) async {
              reached.complete();
              await release.future;
              return _reply('completed');
            };
            final running = h.request(gateway, operation);
            await _bounded(reached.future);
            gateway.close(operation);
            var settled = false;
            final waiting =
                gateway.waitPendingWork().then((_) => settled = true);
            expect(settled, isFalse);
            release.complete();
            expect(await _bounded(running), isA<PreparedDeletionUnconfirmed>());
            await _bounded(waiting);
            expect(settled, isTrue);
            expect((await h.memory.load())!.phase,
                ImmediateDeletionPhase.completed);
            expect((await h.memory.load())!.receiptSecret, isNull);
            expect(await _bounded(h.track(gateway.recover(operation))),
                isA<PreparedDeletionUnconfirmed>());
            expect(h.requests, hasLength(1));
          }));

  for (final loss in ['gate', 'epoch', 'token', 'authLoss']) {
    test(
        '$loss loss after preparation cannot retarget dispatch',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              if (loss == 'gate') {
                TestEgress().install();
              } else if (loss == 'epoch') {
                h.egress.gate.advanceEpoch();
              } else if (loss == 'token') {
                final actual = h.sdk.auth.currentSession!;
                final parts = actual.accessToken.split('.');
                parts[2] = 'synthetic-refreshed-signature';
                await h.sdk.auth.recoverSession(jsonEncode({
                  ...actual.toJson(),
                  'access_token': parts.join('.'),
                }));
                expect(h.sdk.auth.currentSession!.user.id, _owner);
                expect(h.sdk.auth.currentSession!.accessToken,
                    isNot(actual.accessToken));
              } else {
                h.session.markSessionInvalid();
              }
              expect(await _bounded(h.request(gateway, operation)),
                  isA<PreparedDeletionUnconfirmed>());
              expect(h.requests, isEmpty);
            }));
  }

  test(
      'exact issued completion consumes original local replica once without remote effects',
      () => _world((h) async {
            var unlink = 0;
            h.session.configureCaptureDeviceUnlink(() async {
              unlink++;
            });
            try {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              h.answer = (_) async => _reply('completed');
              final evidence = (await _bounded(h.request(gateway, operation)))
                  as PreparedDeletionRemoteCompletion;
              expect(
                  await _bounded(
                      h.gateway().removeOriginalLocalReplica(evidence)),
                  PreparedLocalRemovalOutcome.operationUnavailable);
              expect(
                  h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
              final result =
                  h.track(gateway.removeOriginalLocalReplica(evidence));
              expect(h.session.captureDatabaseHostAdmission(), isNull);
              expect(await _bounded(result),
                  PreparedLocalRemovalOutcome.originalLocalRemovalConfirmed);
              expect(
                  await _bounded(gateway.removeOriginalLocalReplica(evidence)),
                  PreparedLocalRemovalOutcome.operationUnavailable);
              expect(h.requests, hasLength(1));
              // Local-scope sign-out of the deleted owner's SDK session, no request.
              expect(h.sdk.auth.currentSession, isNull);
              expect(unlink, 0);
              expect(await h.fixture.artifactsOf(_owner), isEmpty);
              expect(h.session.removalNoticePending.value, isFalse);
            } finally {
              h.session.configureCaptureDeviceUnlink(null);
            }
          }));

  for (final successor in [_owner, 'prepared-owner-b']) {
    test(
        'actual $successor successor cannot consume old completion or mutate local state',
        () => _world((h) async {
              final gateway = h.gateway();
              final operation = (await _bounded(gateway.prepare()))!;
              h.answer = (_) async => _reply('completed');
              final evidence = (await _bounded(h.request(gateway, operation)))
                  as PreparedDeletionRemoteCompletion;
              if (successor == _owner) {
                await h.admit();
              } else {
                await h.switchTo(successor);
              }
              final current = h.fixture.host.current;
              final before = List<String>.of(h.fixture.storage.attempts);
              final native = List<String>.of(h.fixture.order);
              expect(
                  await _bounded(gateway.removeOriginalLocalReplica(evidence)),
                  PreparedLocalRemovalOutcome.staleBeforeAcceptance);
              expect(h.fixture.storage.attempts, before);
              expect(h.fixture.order, native);
              expect(identical(h.fixture.host.current, current), isTrue);
              expect(
                  h.session.captureDatabaseHostAdmission()?.isCurrent, isTrue);
              expect(h.requests, hasLength(1));
            }));
  }

  test(
      'retained restriction reentry burns evidence before caller code',
      () => _world((h) async {
            final gateway = h.gateway();
            PreparedDeletionRemoteCompletion? evidence;
            Future<PreparedLocalRemovalOutcome>? reentry;
            final operation = (await _bounded(gateway.prepare(restrict: () {
              final issued = evidence;
              if (issued != null && reentry == null) {
                reentry = gateway.removeOriginalLocalReplica(issued);
              }
              return true;
            })))!;
            h.answer = (_) async => _reply('completed');
            evidence = (await _bounded(h.request(gateway, operation)))
                as PreparedDeletionRemoteCompletion;
            expect(
                await _bounded(gateway.removeOriginalLocalReplica(evidence)),
                PreparedLocalRemovalOutcome.originalLocalRemovalConfirmed);
            expect(await _bounded(reentry!),
                PreparedLocalRemovalOutcome.operationUnavailable);
            expect(h.requests, hasLength(1));
          }));
}
