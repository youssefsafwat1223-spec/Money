import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_access_broker.dart';

// Astra R45 R7 — a quiescing coordinator denies EVERY incompatible persistent
// reservation, whichever transition left it quiescing (a timed-out local-read
// restoration whose exclusion object was already released, or an ordinary
// `transition()`), before AND after the uncertain holder finally closes. Pure
// bookkeeping: every "handle" is a synthetic value.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseAccessBroker broker;
  setUp(() => broker = DatabaseAccessBroker.debugUnregistered());
  tearDown(() => broker.debugDispose());

  DatabaseOpenHandle uncertainHolder() {
    final r = broker.reserveAdmissionOpen(
        uid: 'old', admissionIdentity: Object(), lossGeneration: 0);
    return r.registerOpened(Object(), close: () async {});
  }

  /// A local-read restoration that timed out draining and released its
  /// exclusion object while [holder] is still physically open.
  Future<void> timedOutRestoration() async {
    final exclusion = broker.beginLocalReadExclusion();
    await expectLater(
        exclusion.awaitDrained(timeout: const Duration(milliseconds: 30)),
        throwsA(isA<DatabaseAccessUnavailable>()));
    exclusion.release(published: false);
  }

  void expectEveryPersistentReservationDenied() {
    expect(
        () => broker.reserveAdmissionOpen(
            uid: 'x', admissionIdentity: Object(), lossGeneration: 0),
        throwsA(isA<DatabaseAccessUnavailable>()),
        reason: 'admission primary');
    expect(
        () => broker.reserveColdLaunchOpen(
            uid: 'x', launchIdentity: Object(), lossGeneration: 0),
        throwsA(isA<DatabaseAccessUnavailable>()),
        reason: 'cold-launch primary');
    expect(broker.pendingOpens, 0,
        reason: 'a denied reservation adds no holder');
  }

  group('R7 post-timeout quiescing', () {
    test(
        'after a timed-out restoration released its exclusion, nothing '
        'persistent may reserve', () async {
      final holder = uncertainHolder();
      await timedOutRestoration();
      expect(broker.mode, DatabaseAccessMode.quiescing);
      expectEveryPersistentReservationDenied();
      expect(broker.reserveEphemeral, returnsNormally,
          reason: 'the memory-only signed-out database stays available');
      await holder.close();
    });

    test('a late physical close does not silently reopen admission', () async {
      final holder = uncertainHolder();
      await timedOutRestoration();
      await holder.close();
      expect(broker.openHolders, 0);
      expect(broker.mode, DatabaseAccessMode.quiescing,
          reason: 'only an explicit recovery transition leaves quiescing');
      expectEveryPersistentReservationDenied();
    });

    test('an ordinary transition drain refuses reservations while it waits',
        () async {
      final holder = uncertainHolder();
      final draining = broker.transition(DatabaseAccessMode.closed,
          timeout: const Duration(milliseconds: 80));
      final outcome =
          expectLater(draining, throwsA(isA<DatabaseAccessUnavailable>()));
      await Future<void>.delayed(Duration.zero);
      expect(broker.mode, DatabaseAccessMode.quiescing);
      expectEveryPersistentReservationDenied();
      await outcome;
      // The transition timed out: still quiescing, still denied.
      expect(broker.mode, DatabaseAccessMode.quiescing);
      expectEveryPersistentReservationDenied();
      await holder.close();
    });
  });

  group('R7 explicit recovery transition', () {
    test('refused while any physical holder remains, pending or open',
        () async {
      final pending = broker.reserveAdmissionOpen(
          uid: 'old', admissionIdentity: Object(), lossGeneration: 0);
      await timedOutRestoration();
      expect(broker.recoverFromQuiescing(), isFalse);
      expect(broker.mode, DatabaseAccessMode.quiescing);
      final handle = pending.registerOpened(Object(), close: () async {});
      expect(broker.recoverFromQuiescing(), isFalse);
      await handle.close();
      expect(broker.recoverFromQuiescing(), isTrue);
    });

    test('a failed physical close never counts', () async {
      final r = broker.reserveAdmissionOpen(
          uid: 'old', admissionIdentity: Object(), lossGeneration: 0);
      final handle = r.registerOpened(Object(),
          close: () async => throw StateError('close failed'));
      await timedOutRestoration();
      await expectLater(handle.close(), throwsStateError);
      expect(broker.recoverFromQuiescing(), isFalse);
      expect(broker.mode, DatabaseAccessMode.quiescing);
    });

    test(
        'after the holders closed it returns to closed, never writable, '
        'and revives no old reservation', () async {
      final r = broker.reserveAdmissionOpen(
          uid: 'old', admissionIdentity: Object(), lossGeneration: 0);
      final handle = r.registerOpened(Object(), close: () async {});
      await timedOutRestoration();
      await handle.close();
      expect(broker.recoverFromQuiescing(), isTrue);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse, reason: 'no job authority');
      expect(r.isCurrent, isFalse, reason: 'old generation never revives');
      // Persistent reservations are possible again, as a fresh generation.
      final fresh = broker.reserveAdmissionOpen(
          uid: 'new', admissionIdentity: Object(), lossGeneration: 0);
      expect(fresh.isCurrent, isTrue);
      expect(broker.recoverFromQuiescing(), isFalse,
          reason: 'nothing is quiescing any more');
    });

    test('is refused while a transition or an exclusion owns the coordinator',
        () async {
      final exclusion = broker.beginLocalReadExclusion();
      expect(broker.recoverFromQuiescing(), isFalse);
      exclusion.release(published: false);
      // Now unowned and empty: the release itself already returned to closed.
      expect(broker.mode, DatabaseAccessMode.closed);

      final holder = uncertainHolder();
      final draining = broker.transition(DatabaseAccessMode.closed,
          timeout: const Duration(milliseconds: 200));
      final settled =
          expectLater(draining, throwsA(isA<DatabaseAccessUnavailable>()));
      await Future<void>.delayed(Duration.zero);
      expect(broker.recoverFromQuiescing(), isFalse);
      await settled;
      await holder.close();
      expect(broker.recoverFromQuiescing(), isTrue);
    });

    test(
        'an old holder close acknowledgement still releases exactly its own '
        'holder after recovery bookkeeping', () async {
      final r = broker.reserveAdmissionOpen(
          uid: 'old', admissionIdentity: Object(), lossGeneration: 0);
      final handle = r.registerOpened(Object(), close: () async {});
      await timedOutRestoration();
      expect(broker.openHolders, 1);
      await handle.close();
      expect(broker.openHolders, 0);
      expect(broker.pendingOpens, 0);
    });
  });
}
