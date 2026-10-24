import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/database_access_broker.dart';

// O-H1 — the inert coordinator and the private single-opener reservation
// ledger. Nothing here opens a database: every "handle" is a synthetic value
// and every close is a spy, so the tests are about bookkeeping and refusal.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('unregistered (test) coordinator ledger', () {
    late DatabaseAccessBroker broker;
    setUp(() => broker = DatabaseAccessBroker.debugUnregistered());
    tearDown(() => broker.debugDispose());

    test('is inert: no issuer, no client authority, no mode, no maintenance',
        () async {
      expect(broker.isInert, isTrue);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse);
      await expectLater(broker.transition(DatabaseAccessMode.writable),
          throwsA(isA<DatabaseAccessUnavailable>()));
      await expectLater(broker.transition(DatabaseAccessMode.maintenance),
          throwsA(isA<DatabaseAccessUnavailable>()));
      await expectLater(broker.transition(DatabaseAccessMode.localRead),
          throwsA(isA<DatabaseAccessUnavailable>()));
      // A reserve through the communication endpoint is denied too.
      var attempts = 0;
      await expectLater(
          DatabaseBrokerClient(broker.endpoint).open<int>(
              open: () async {
                attempts++;
                return 1;
              },
              close: (_) async {}),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(attempts, 0);
    });

    test('admission reservation binds uid, identity, loss, nonce, generation',
        () {
      final identity = Object();
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: identity, lossGeneration: 7);
      expect(reservation.kind, DatabaseReservationKind.admissionPrimary);
      expect(reservation.uid, 'uid-a');
      expect(identical(reservation.admissionIdentity, identity), isTrue);
      expect(reservation.lossGeneration, 7);
      expect(reservation.coordinatorNonce, broker.processNonce);
      expect(reservation.transitionGeneration, 0);
      expect(reservation.isCurrent, isTrue);
      // Reserved BEFORE any handle exists: it is a pending open.
      expect(broker.pendingOpens, 1);
      expect(broker.openHolders, 0);
      // It authorizes nothing but its own opening.
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse);
      expect(reservation.isPromoted, isFalse);
    });

    test('registered handle stays tracked until its close really succeeds',
        () async {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      final db = Object();
      var closes = 0;
      var failClose = true;
      final handle = reservation.registerOpened(db, close: () async {
        closes++;
        if (failClose) throw StateError('close failed');
      });
      expect(reservation.hasOpened, isTrue);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
      await expectLater(handle.close(), throwsStateError);
      expect(closes, 1);
      // A failed close never counts as release, and the cached failure is not
      // physical-close proof on a repeat.
      expect(broker.openHolders, 1);
      await expectLater(handle.close(), throwsStateError);
      expect(closes, 1);
      expect(broker.openHolders, 1);
      // Maintenance-style drain cannot complete while the holder is tracked.
      await expectLater(
          broker.transition(DatabaseAccessMode.closed,
              timeout: const Duration(milliseconds: 30)),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(broker.openHolders, 1);
      failClose = false;
    });

    test('successful close releases the holder and completes a drain',
        () async {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      final handle = reservation.registerOpened(Object(), close: () async {});
      final draining = broker.transition(DatabaseAccessMode.closed,
          timeout: const Duration(seconds: 2));
      // The transition restricted synchronously; the reservation is stale now
      // but its real handle must still be closable and tracked until then.
      await Future<void>.delayed(Duration.zero);
      expect(reservation.isCurrent, isFalse);
      expect(broker.openHolders, 1);
      await handle.close();
      await draining;
      expect(broker.openHolders, 0);
      expect(broker.pendingOpens, 0);
    });

    test('stale reservation still tracks the real handle it registers',
        () async {
      var valid = true;
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a',
          admissionIdentity: Object(),
          lossGeneration: 3,
          stillValid: () => valid);
      valid = false; // loss while the opener was running
      expect(reservation.isCurrent, isFalse);
      expect(() => reservation.requireCurrent(),
          throwsA(isA<StaleAdmissionException>()));
      final handle = reservation.registerOpened(Object(), close: () async {});
      expect(broker.openHolders, 1, reason: 'real handle is never forgotten');
      expect(reservation.promoteCommitted(handle.value, uid: 'uid-a'), isFalse);
      await handle.close();
      expect(broker.openHolders, 0);
    });

    test('promotion needs the exact current registered handle', () async {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      final db = Object();
      expect(reservation.promoteCommitted(db, uid: 'uid-a'), isFalse,
          reason: 'nothing registered yet');
      final handle = reservation.registerOpened(db, close: () async {});
      expect(reservation.promoteCommitted(Object(), uid: 'uid-a'), isFalse,
          reason: 'a different handle is not the reserved one');
      expect(reservation.promoteCommitted(db, uid: 'uid-b'), isFalse,
          reason: 'another uid is not the reserved one');
      expect(reservation.promoteCommitted(db, uid: 'uid-a'), isTrue);
      expect(reservation.isPromoted, isTrue);
      // Promotion still grants no broker authority.
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse);
      await handle.close();
    });

    test('an unopened reservation is released only when explicitly known',
        () {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      expect(broker.pendingOpens, 1);
      reservation.releaseUnopened();
      expect(broker.pendingOpens, 0);
      expect(reservation.isCurrent, isFalse);
    });

    test('releaseUnopened cannot forget a registered handle', () async {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      final handle = reservation.registerOpened(Object(), close: () async {});
      reservation.releaseUnopened();
      expect(broker.openHolders, 1);
      await handle.close();
      expect(broker.openHolders, 0);
    });

    test('ephemeral reservation is tracked, accountless and grants nothing',
        () async {
      final reservation = broker.reserveEphemeral();
      expect(reservation.kind, DatabaseReservationKind.ephemeralSignedOut);
      expect(reservation.uid, isNull);
      expect(reservation.admissionIdentity, isNull);
      expect(broker.pendingOpens, 1);
      final handle = reservation.registerOpened(Object(), close: () async {});
      expect(broker.openHolders, 1);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse);
      expect(reservation.promoteCommitted(handle.value, uid: 'x'), isFalse,
          reason: 'an ephemeral handle is never promoted to account authority');
      await handle.close();
      expect(broker.openHolders, 0);
    });

    test('remote messages cannot close or forge a ledger holder', () async {
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      final handle = reservation.registerOpened(Object(), close: () async {});
      final reply = ReceivePort();
      final answers = StreamIterator<dynamic>(reply);
      for (final command in ['closed', 'opened']) {
        broker.endpoint.send(
            [command, broker.processNonce, 0, 'guess', null, reply.sendPort]);
        expect(await answers.moveNext(), isTrue);
        expect((answers.current as List)[0], 'denied');
      }
      await answers.cancel();
      reply.close();
      expect(broker.openHolders, 1);
      await handle.close();
    });
  });

  group('registered coordinator', () {
    test('created once, retained and reused; discovery gets no authority',
        () {
      expect(DatabaseAccessBroker.discover(), isNull);
      final first = DatabaseAccessBroker.createInert();
      final again = DatabaseAccessBroker.createInert();
      expect(identical(first, again), isTrue,
          reason: 'retries reuse the retained coordinator');
      expect(first.isInert, isTrue);
      expect(first.mode, DatabaseAccessMode.closed);
      final discovered = DatabaseAccessBroker.discover();
      expect(discovered, isNotNull);
      expect(discovered!.isHostIssued, isFalse);
    });

    test('a background entry point can discover but never create', () {
      // Runs last in this file: the mark is process-wide in this isolate.
      DatabaseAccessBroker.markBackgroundEntrypoint();
      expect(() => DatabaseAccessBroker.createInert(),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(DatabaseAccessBroker.discover(), isNotNull);
    });
  });
}
