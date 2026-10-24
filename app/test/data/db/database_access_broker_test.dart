import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';

// Actual independently scheduled Dart isolate. All coordination uses SendPorts;
// no shared boolean/count pretends to establish cross-isolate exclusion.
Future<void> _openerIsolate(List<dynamic> args) async {
  final client = args[0] as DatabaseBrokerClient;
  final report = args[1] as SendPort;
  final control = ReceivePort();
  final commands = StreamIterator<dynamic>(control);
  report.send(['control', control.sendPort]);
  try {
    final holder = await client.open<int>(
      open: () async {
        report.send(['openAttempt']);
        await commands.moveNext();
        return 1;
      },
      close: (_) async {
        report.send(['closeAttempt']);
        await commands.moveNext();
      },
    );
    report.send(['published']);
    await commands.moveNext();
    await holder.close();
    report.send(['closed']);
  } catch (error) {
    report.send(['refused', error.toString()]);
  } finally {
    await commands.cancel();
    control.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture fixture;
  late SupabaseClient sdk;
  late DatabaseAccessBroker broker;
  var firstSdkBinding = true;

  Future<void> publishSdkAdmission() async {
    final admissionSdk = sdk.auth.currentSession;
    expect(admissionSdk, isNotNull,
        reason: 'SDK session exists before admission');
    expect(admissionSdk!.isExpired, isFalse, reason: 'SDK admission is fresh');
    bool current() {
      final actual = sdk.auth.currentSession;
      return actual != null &&
          !actual.isExpired &&
          actual.user.id == admissionSdk.user.id &&
          actual.accessToken == admissionSdk.accessToken;
    }

    await fixture.session.setIdentity(
      method: 'apple',
      email: admissionSdk.user.email,
      userId: admissionSdk.user.id,
      sessionCurrent: current,
    );
    await fixture.session.finishOnboarding(client: sdk);
    if (firstSdkBinding) {
      // GoTrue replays its cached recovery event on subscription. The direct
      // bind reconcile can finish before that real event's ownership lane.
      // Wait its actual completion; neither a delay nor authenticated status
      // alone establishes that the removal/admission checks have settled.
      final cachedEventSettled = Completer<void>();
      fixture.session.debugAuthEventCompleted = (event) {
        if (event == AuthChangeEvent.tokenRefreshed &&
            !cachedEventSettled.isCompleted) {
          cachedEventSettled.complete();
        }
      };
      try {
        await fixture.session.bindSupabaseAuth(sdk);
        await cachedEventSettled.future;
      } finally {
        fixture.session.debugAuthEventCompleted = null;
      }
      firstSdkBinding = false;
    } else {
      await fixture.session.bindSupabaseAuth(sdk);
    }
    expect(fixture.flow.isRunning, isFalse,
        reason: 'Real removal admission checks settled');
    expect(current(), isTrue,
        reason: 'Actual SDK remains current after publication');
    expect(fixture.session.status.name, 'authenticated',
        reason: 'Committed status');
    expect(fixture.session.hasCompletedOnboarding, isTrue,
        reason: 'Committed onboarding');
    expect(fixture.session.isGuest, isFalse,
        reason: 'Authenticated host is not a guest');
    final scope = fixture.host.current;
    expect(scope, isNotNull, reason: 'Actual scope is published');
    expect(scope!.uid == admissionSdk.user.id, isTrue,
        reason: 'Exact scope owner');
    expect(scope.database.isReadOnly, isFalse, reason: 'Writable scope');
    expect(scope.database.admitsSecondary, isTrue,
        reason: 'Actual database is usable');
  }

  setUpAll(() async {
    fixture = await F2Fixture.create();
    fixture.session.configureAccountScope(fixture.host);
    sdk = await fixture.clientFor('broker-owner');
    await publishSdkAdmission();
    expect(DatabaseAccessBroker.discover(), isNull);
    final localWork = fixture.session.captureLocalWorkAuthority();
    expect(localWork, isNotNull, reason: 'Published host local work admission');
    expect(localWork!.isCurrent, isTrue,
        reason: 'Actual private admission current');
    final receipt = fixture.session.captureDatabaseHostAdmission();
    expect(receipt, isNotNull);
    broker = DatabaseAccessBroker.start(receipt!);
  });

  tearDownAll(() async {
    await fixture.dispose();
    await sdk.dispose();
  });

  Future<void> writable() async {
    final receipt = fixture.session.captureDatabaseHostAdmission();
    expect(receipt, isNotNull);
    await broker.transition(DatabaseAccessMode.writable, admission: receipt);
  }

  test('actual committed host permits reservation, open and confirmed close',
      () async {
    final storageAttempts = List<String>.of(fixture.storage.attempts);
    await writable();
    var openAttempts = 0;
    var closeAttempts = 0;
    final holder = await broker.client.open<int>(open: () async {
      openAttempts++;
      return 1;
    }, close: (_) async {
      closeAttempts++;
    });
    expect(openAttempts, 1);
    expect(broker.openHolders, 1);
    await holder.close();
    expect(closeAttempts, 1);
    expect(broker.openHolders, 0);
    await broker.transition(DatabaseAccessMode.closed);
    expect(fixture.storage.attempts, storageAttempts);
  });

  test('no host issuer and unimplemented read scope deny before open attempts',
      () async {
    var attempts = 0;
    await expectLater(
        broker.client.open<int>(
            open: () async {
              attempts++;
              return 1;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    await expectLater(broker.transition(DatabaseAccessMode.localRead),
        throwsA(isA<DatabaseAccessUnavailable>()));
    await expectLater(broker.transition(DatabaseAccessMode.maintenance),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 0);
  });

  test('separate isolate pending open loses publication until actual close',
      () async {
    await writable();
    final reports = ReceivePort();
    final events = StreamIterator<dynamic>(reports);
    final worker =
        await Isolate.spawn(_openerIsolate, [broker.client, reports.sendPort]);
    await events.moveNext();
    final control = events.current[1] as SendPort;
    await events.moveNext();
    expect(events.current[0], 'openAttempt');
    expect(broker.pendingOpens, 1);
    var transitioned = false;
    final transition = broker
        .transition(DatabaseAccessMode.closed)
        .then((_) => transitioned = true);
    expect(broker.mode, DatabaseAccessMode.quiescing);
    control.send('finishOpen');
    await events.moveNext();
    expect(events.current[0], 'closeAttempt');
    expect(broker.openHolders, 1);
    expect(transitioned, isFalse);
    var deniedAttempts = 0;
    await expectLater(
        broker.client.open<int>(
            open: () async {
              deniedAttempts++;
              return 2;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(deniedAttempts, 0);
    control.send('finishClose');
    await events.moveNext();
    expect(events.current[0], 'refused');
    await transition;
    expect(broker.openHolders, 0);
    await events.cancel();
    reports.close();
    worker.kill();
  });

  test('separate isolate active holder blocks mode switch until actual close',
      () async {
    await writable();
    final reports = ReceivePort();
    final events = StreamIterator<dynamic>(reports);
    final worker =
        await Isolate.spawn(_openerIsolate, [broker.client, reports.sendPort]);
    await events.moveNext();
    final control = events.current[1] as SendPort;
    await events.moveNext();
    expect(events.current[0], 'openAttempt');
    control.send('finishOpen');
    await events.moveNext();
    expect(events.current[0], 'published');
    var transitioned = false;
    final transition = broker
        .transition(DatabaseAccessMode.closed)
        .then((_) => transitioned = true);
    control.send('close');
    await events.moveNext();
    expect(events.current[0], 'closeAttempt');
    expect(transitioned, isFalse);
    expect(broker.openHolders, 1);
    control.send('finishClose');
    await events.moveNext();
    expect(events.current[0], 'closed');
    await transition;
    await events.cancel();
    reports.close();
    worker.kill();
  });

  test('missing, unresponsive and dead coordinators never attempt opening',
      () async {
    var attempts = 0;
    for (final dead in [false, true]) {
      final endpoint = ReceivePort();
      final client = DatabaseBrokerClient(endpoint.sendPort,
          timeout: const Duration(milliseconds: 20));
      if (dead) endpoint.close();
      await expectLater(
          client.open<int>(
              open: () async {
                attempts++;
                return 1;
              },
              close: (_) async {}),
          throwsA(isA<DatabaseAccessUnavailable>()));
      endpoint.close();
    }
    expect(attempts, 0);
  });

  test(
      'repeat capture preserves exact current issuer and writable reservations',
      () async {
    await writable();
    final old = fixture.session.captureDatabaseHostAdmission()!;
    final current = fixture.session.captureDatabaseHostAdmission()!;
    expect(identical(old, current), isTrue);
    expect(old.isCurrent, isTrue);
    var attempts = 0;
    final holder = await broker.client.open<int>(
        open: () async {
          attempts++;
          return 1;
        },
        close: (_) async {});
    expect(attempts, 1);
    await holder.close();
    await broker.transition(DatabaseAccessMode.closed);
  });

  test('same UID genuine readmission never revives a lost host receipt',
      () async {
    await writable();
    final priorClient = broker.client;
    final old = fixture.session.captureDatabaseHostAdmission()!;
    fixture.session.markSessionInvalid();
    // No current getter observes the loss before a genuine new publication.
    await publishSdkAdmission();
    final fresh = fixture.session.captureDatabaseHostAdmission()!;
    expect(identical(old, fresh), isFalse);
    expect(old.isCurrent, isFalse);
    expect(fresh.isCurrent, isTrue);
    var attempts = 0;
    await expectLater(
        broker.client.open<int>(
            open: () async {
              attempts++;
              return 1;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 0);
    await broker.transition(DatabaseAccessMode.closed);
    await broker.transition(DatabaseAccessMode.writable, admission: fresh);
    var staleAttempts = 0;
    await expectLater(
        priorClient
            .open<int>(
                open: () async {
                  staleAttempts++;
                  return 2;
                },
                close: (_) async {})
            .then((holder) async {
          await holder.close();
          return holder;
        }),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(staleAttempts, 0);
    final holder = await broker.client.open<int>(
        open: () async {
          attempts++;
          return 1;
        },
        close: (_) async {});
    expect(attempts, 1);
    await holder.close();
    await broker.transition(DatabaseAccessMode.closed);

    // Changing away from and back to the same controller without consulting
    // isCurrent likewise cannot resurrect its previously captured receipt.
    fixture.session.configureAccountScope(fixture.scope);
    fixture.session.configureAccountScope(fixture.host);
    await publishSdkAdmission();
    final afterControllerChange =
        fixture.session.captureDatabaseHostAdmission()!;
    expect(fresh.isCurrent, isFalse);
    expect(afterControllerChange.isCurrent, isTrue);
    expect(identical(fresh, afterControllerChange), isFalse);
  });

  test('retained prior-owner client cannot reserve after another owner commits',
      () async {
    await writable();
    final priorClient = broker.client;
    final previousSdk = sdk;
    sdk = await fixture.clientFor('broker-next-owner');
    await publishSdkAdmission();
    await previousSdk.dispose();
    final admission = fixture.session.captureDatabaseHostAdmission()!;
    await broker.transition(DatabaseAccessMode.writable, admission: admission);
    var staleAttempts = 0;
    await expectLater(
        priorClient
            .open<int>(
                open: () async {
                  staleAttempts++;
                  return 1;
                },
                close: (_) async {})
            .then((holder) async {
          await holder.close();
          return holder;
        }),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(staleAttempts, 0);
    var currentAttempts = 0;
    final holder = await broker.client.open<int>(
        open: () async {
          currentAttempts++;
          return 2;
        },
        close: (_) async {});
    expect(currentAttempts, 1);
    await holder.close();
    await broker.transition(DatabaseAccessMode.closed);
  });

  test('discovery and arbitrary tokens deny before an opening attempt',
      () async {
    await writable();
    var attempts = 0;
    for (final client in [
      DatabaseAccessBroker.discover()!,
      DatabaseBrokerClient(broker.endpoint),
    ]) {
      await expectLater(
          client.open<int>(
              open: () async {
                attempts++;
                return 1;
              },
              close: (_) async {}),
          throwsA(isA<DatabaseAccessUnavailable>()));
    }
    expect(attempts, 0);
    final reply = ReceivePort();
    broker.endpoint.send([
      'reserve',
      broker.processNonce,
      0,
      null,
      Capability(),
      reply.sendPort
    ]);
    expect((await reply.first as List<dynamic>)[0], 'denied');
    reply.close();
    expect(broker.pendingOpens, 0);
    expect(broker.openHolders, 0);
    await broker.transition(DatabaseAccessMode.closed);
  });

  test('host job permit admits only its single reserved opener', () async {
    await writable();
    final client = broker.client;
    var attempts = 0;
    final holder = await client.open<int>(
        open: () async {
          attempts++;
          return 1;
        },
        close: (_) async {});
    await holder.close();
    await expectLater(
        client.open<int>(
            open: () async {
              attempts++;
              return 2;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 1);
    await broker.transition(DatabaseAccessMode.closed);
  });

  test('lost actual SDK denies retained job before opening and stays revoked',
      () async {
    await writable();
    final receipt = fixture.session.captureDatabaseHostAdmission()!;
    final client = broker.client;
    final owner = sdk.auth.currentSession!.user.id;
    await sdk.auth.signOut(scope: SignOutScope.local);
    var attempts = 0;
    await expectLater(
        client.open<int>(
            open: () async {
              attempts++;
              return 1;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 0);
    expect(receipt.isCurrent, isFalse);
    await fixture.recoverSession(sdk, owner);
    await publishSdkAdmission();
    final fresh = fixture.session.captureDatabaseHostAdmission()!;
    expect(receipt.isCurrent, isFalse);
    expect(fresh.isCurrent, isTrue);
    await broker.transition(DatabaseAccessMode.writable, admission: fresh);
    await expectLater(
        client.open<int>(
            open: () async {
              attempts++;
              return 2;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 0);
    await broker.transition(DatabaseAccessMode.closed);
  });

  test('unknown open and failed close retain holders and deny maintenance',
      () async {
    await writable();
    var closeAttempts = 0;
    final holder = await broker.client.open<int>(
        open: () async => 1,
        close: (_) async {
          closeAttempts++;
          throw StateError('unknown close');
        });
    await expectLater(holder.close(), throwsStateError);
    await expectLater(holder.close(), throwsStateError);
    var failedOpenAttempts = 0;
    await expectLater(
        broker.client.open<int>(
            open: () async {
              failedOpenAttempts++;
              throw StateError('unknown open');
            },
            close: (_) async {}),
        throwsStateError);
    expect(failedOpenAttempts, 1);
    expect(broker.pendingOpens, 1);
    expect(closeAttempts, 1);
    final receipt = fixture.session.captureDatabaseHostAdmission()!;
    await expectLater(
        broker.transition(DatabaseAccessMode.maintenance,
            admission: receipt, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(broker.mode, DatabaseAccessMode.quiescing);
    expect(broker.openHolders, 1);
    expect(() => DatabaseAccessBroker.start(receipt),
        throwsA(isA<DatabaseAccessUnavailable>()));
  });
}
