import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';

import '../../harness/egress_test_support.dart';

/// Astra G P1 / C.4: the durable denial state and the ONE admission gate.
void main() {
  late TestEgress egress;
  late CloudEgressGate gate;

  Future<void> putOn({String owner = 'uid-a', int gen = 1}) async {
    await gate.writeRecord(CloudEgressRecord(
        state: EgressState.on,
        ownerUid: owner,
        transitionGeneration: gen,
        reservedVersion: 1));
  }

  setUp(() {
    egress = TestEgress().install();
    gate = egress.gate;
  });

  Future<Object?> admitError([EgressGrant? grant]) async {
    try {
      final t = await gate.admit(grant: grant);
      gate.release(t);
      return null;
    } on EgressDeniedException catch (e) {
      return e.reason;
    }
  }

  group('admission', () {
    test('no record (never enabled) and OFF deny automatic traffic', () async {
      expect(await admitError(), 'off');
      await gate.writeRecord(const CloudEgressRecord(
          state: EgressState.off,
          ownerUid: 'uid-a',
          transitionGeneration: 2,
          reservedVersion: 2));
      expect(await admitError(), 'off');
    });

    test('ON admits, and registers the request in the in-flight set', () async {
      await putOn();
      final t = await gate.admit();
      expect(gate.inFlightCount, 1);
      gate.release(t);
      expect(gate.inFlightCount, 0);
    });

    test('no request newly passes admission after DISABLING began, including '
        'concurrent attempts', () async {
      await putOn();
      final admittedBefore = <EgressTicket>[];
      final outcomes = <String>[];
      Future<void> attempt(String label) async {
        try {
          final t = await gate.admit();
          admittedBefore.add(t);
          outcomes.add('$label:admitted');
        } on EgressDeniedException {
          outcomes.add('$label:denied');
        }
      }

      final early = [for (var i = 0; i < 5; i++) attempt('early$i')];
      final disabling =
          gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      final late = [for (var i = 0; i < 20; i++) attempt('late$i')];
      await Future.wait([...early, disabling, ...late]);

      expect(outcomes.where((o) => o.startsWith('late')),
          everyElement(endsWith(':denied')));
      expect(outcomes.where((o) => o.startsWith('early')),
          everyElement(endsWith(':admitted')),
          reason: 'queued BEFORE the disable: admitted before DISABLING');
      // And everything after the durable write, from any caller:
      expect(await admitError(), 'disabling');
      expect(egress.secure.value, contains('DISABLING'));
      expect(egress.file.value, contains('DISABLING'));
    });

    test('a corrupt store denies egress', () async {
      await putOn();
      egress.file.value = '{not json';
      expect(await admitError(), 'state_uncertain');
      expect(await gate.permits(), isFalse);
      egress.file.value = '{"v":1,"records":{"uid-a":{"state":"BOGUS"}}}';
      expect(await admitError(), 'state_uncertain');
    });

    test('an unreadable store denies egress (either store)', () async {
      await putOn();
      egress.secure.failReads = true;
      expect(await admitError(), 'state_uncertain');
      egress.secure.failReads = false;
      egress.file.failReads = true;
      expect(await admitError(), 'state_uncertain');
      egress.file.failReads = false;
      expect(await admitError(), isNull, reason: 'a clean read admits again');
    });

    test('the in-process freeze denies everything but the revoke', () async {
      await putOn();
      ConsentAuthority.egressFrozen = true;
      expect(await admitError(), 'frozen');
      expect(await admitError(const EgressGrant.userInitiated()), 'frozen');
      ConsentAuthority.egressFrozen = false;
    });
  });

  group('the only exceptions', () {
    test('an explicit user action (sign-in) is admitted in OFF/unset, never in '
        'DISABLING; automatic traffic never', () async {
      expect(await admitError(), 'off');
      expect(await admitError(const EgressGrant.userInitiated()), isNull);
      final viaZone = await gate.runUserInitiated(() => admitError());
      expect(viaZone, isNull);
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await admitError(const EgressGrant.userInitiated()), 'disabling');
    });

    test('the revoke is admitted only in DISABLING and only for its own owner '
        'and generation', () async {
      await putOn();
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await admitError(freeze.revokeGrant), isNull);
      expect(
          await admitError(
              const EgressGrant.revoke(owner: 'uid-b', generation: 2)),
          'disabling');
      expect(
          await admitError(
              const EgressGrant.revoke(owner: 'uid-a', generation: 99)),
          'disabling');
      await gate.commitOff(freeze);
      expect(await admitError(freeze.revokeGrant), 'revoke_outside_disabling');
    });
  });

  group('transition and reconciliation rules', () {
    test('the generation advances before the freeze; ON on enable is strictly '
        'greater; version too', () async {
      final on1 = await gate.enable(owner: 'uid-a', reservedVersion: 2);
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 3);
      expect(freeze.transitionGeneration, greaterThan(on1.transitionGeneration));
      expect(await gate.commitOff(freeze), isTrue);
      final off = (await gate.view(owner: 'uid-a')).record!;
      expect(off.state, EgressState.off);
      expect(off.transitionGeneration, freeze.transitionGeneration,
          reason: 'OFF at commit carries the SAME generation as DISABLING');
      final on2 = await gate.enable(owner: 'uid-a', reservedVersion: 4);
      expect(on2.transitionGeneration, greaterThan(off.transitionGeneration));
      expect(on2.reservedVersion, greaterThan(off.reservedVersion));
    });

    test('DISABLING in ONE store overrides its absence in the other', () async {
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      egress.file.value = null;
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling);
      expect(await admitError(), 'disabling');
    });

    test('a restrictive record beats ON in the other store; OFF (the commit) '
        'beats DISABLING at the same generation', () async {
      await gate.enable(owner: 'uid-a', reservedVersion: 2);
      final onJson = egress.file.value!;
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 3);
      egress.file.value = onJson; // the file still says ON
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling);
      await gate.commitOff(freeze);
      egress.secure.value = egress.secure.value!.replaceAll('"OFF"', '"DISABLING"');
      expect((await gate.view(owner: 'uid-a')).record!.state, EgressState.off);
    });

    test('a marker for owner A survives B\'s writes and is not applied to B',
        () async {
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await gate.enable(owner: 'uid-b', reservedVersion: 5);
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling,
          reason: 'never silently discarded');
      expect((await gate.view(owner: 'uid-b')).record!.state, EgressState.on);
      egress.owner = 'uid-b';
      expect(await admitError(), isNull, reason: 'B is evaluated on its own');
      egress.owner = 'uid-a';
      expect(await admitError(), 'disabling');
    });

    test('failure to establish DISABLING in at least one store throws', () async {
      egress.secure.failWrites = true;
      egress.file.failWrites = true;
      await expectLater(
          gate.beginDisabling(owner: 'uid-a', reservedVersion: 2),
          throwsA(isA<EgressWriteFailedException>()));
      egress.file.failWrites = false;
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(freeze.transitionGeneration, 1);
    });

    test('enable needs EVERY store; a partial write cannot widen', () async {
      egress.file.failWrites = true;
      await expectLater(gate.enable(owner: 'uid-a', reservedVersion: 2),
          throwsA(isA<EgressWriteFailedException>()));
      expect(await admitError(), isNotNull);
    });
  });

  group('native (iOS) copy', () {
    test('a native DISABLING record overrides absence in the Dart stores',
        () async {
      CloudEgressRecord? nativeRec;
      final native = NativeEgressSlot(
        read: (owner) async => nativeRec?.ownerUid == owner ? nativeRec : null,
        write: (r) async => nativeRec = r,
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      nativeRec = const CloudEgressRecord(
          state: EgressState.disabling,
          ownerUid: 'uid-a',
          transitionGeneration: 3,
          reservedVersion: 3);
      expect(await admitError(), 'disabling');
    });

    test('an unavailable / uncertain native store fails closed, and every '
        'write reaches it', () async {
      var fail = true;
      CloudEgressRecord? rec;
      final native = NativeEgressSlot(
        read: (o) async {
          if (fail) throw StateError('bridge unavailable');
          return rec;
        },
        write: (r) async => rec = r,
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      expect(await admitError(), 'state_uncertain');
      fail = false;
      final on = await gate.enable(owner: 'uid-a', reservedVersion: 2);
      expect(rec, on, reason: 'the iOS copy is written with the same record');
      expect(await admitError(), isNull);
    });
  });

  group('in-flight handling (C.4)', () {
    test('drain waits for an admitted request, then cancels what is still '
        'running (bounded)', () async {
      await putOn();
      final fast = await gate.admit();
      final slow = await gate.admit();
      Timer(const Duration(milliseconds: 20), () => gate.release(fast));
      final sw = Stopwatch()..start();
      final r = await gate.drain();
      expect(r.cancelled, 1);
      expect(slow.isCancelled, isTrue);
      expect(fast.isCancelled, isFalse);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)),
          reason: 'it waited for the bound (200 ms in this harness)');
      expect(gate.inFlightCount, 0);
    });

    test('drain returns as soon as the set is empty', () async {
      await putOn();
      final t = await gate.admit();
      Timer(const Duration(milliseconds: 20), () => gate.release(t));
      final r = await gate.drain();
      expect(r.cancelled, 0);
      expect(t.isCancelled, isFalse);
    });

    test('an in-flight transport that returns after the transition has no '
        'effect: its response is discarded', () async {
      await putOn();
      final inner = Completer<http.Response>();
      final client = GatedHttpClient(MockClient((_) => inner.future));
      final call = client.get(Uri.parse('https://x.invalid/a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gate.inFlightCount, 1);
      gate.advanceEpoch(); // disable / enable / account switch began
      inner.complete(http.Response('{"ok":true}', 200));
      await expectLater(call, throwsA(isA<EgressDeniedException>()));
      expect(gate.inFlightCount, 0);
    });

    test('a request still running at the drain bound is cancelled and its '
        'caller gets an error, not a result', () async {
      await putOn();
      final client = GatedHttpClient(MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('late', 200);
      }));
      final call = client.get(Uri.parse('https://x.invalid/a'));
      final caught = expectLater(call, throwsA(isA<EgressDeniedException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final r = await gate.drain();
      expect(r.cancelled, 1);
      await caught;
    });

    test('native extension uploads are waited for, bounded', () async {
      var polls = 0;
      final g = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 300),
        nativePoll: const Duration(milliseconds: 10),
        nativeInflight: (_) async {
          polls++;
          return (count: polls < 4 ? 1 : 0, latestDeadline: null);
        },
      );
      await g.drainNative('uid-a');
      expect(polls, 4);

      final stuck = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 120),
        nativePoll: const Duration(milliseconds: 10),
        nativeInflight: (_) async => (count: 3, latestDeadline: null),
      );
      final sw = Stopwatch()..start();
      await stuck.drainNative('uid-a');
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      final unavailable = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 120),
        nativeInflight: (_) async => null,
      );
      final sw2 = Stopwatch()..start();
      await unavailable.drainNative('uid-a');
      expect(sw2.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)),
          reason: 'unavailable = wait out the whole bound');
    });
  });

  group('background / resume transports are the same gate', () {
    test('a gated transport sends nothing in DISABLING and after OFF, and '
        'sends again only after an explicit enable', () async {
      var sent = 0;
      final client = GatedHttpClient(MockClient((_) async {
        sent++;
        return http.Response('{}', 200);
      }));
      Future<bool> tryGet() async {
        try {
          await client.get(Uri.parse('https://x.invalid/bg'));
          return true;
        } on EgressDeniedException {
          return false;
        }
      }

      await putOn();
      expect(await tryGet(), isTrue);
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await tryGet(), isFalse);
      await gate.commitOff(freeze);
      expect(await tryGet(), isFalse);
      expect(sent, 1);
      await gate.enable(owner: 'uid-a', reservedVersion: 3);
      expect(await tryGet(), isTrue);
      expect(sent, 2);
    });

    test('the permit mirror drives the auto-refresh policy', () async {
      await putOn();
      final seen = <bool>[];
      gate.onPermitChanged = (p) async => seen.add(p);
      await gate.refresh();
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(seen, [true, false]);
      expect(gate.permitsNetworkSync, isFalse);
    });
  });
}
