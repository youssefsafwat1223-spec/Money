import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/egress_test_support.dart';

// Startup resolution ownership. The reconciliation that resolves the process
// latch has two separate questions: is this still the designated initialization
// attempt (resolution OWNERSHIP) and may it still mutate (the strict lifetime /
// epoch checks)? An attempt that lost its mutation authority but still owns the
// resolution ends RESTRICTIVELY (a tagged freeze, no thaw, no repair) and
// resolves; a superseded attempt does neither. No timer, no unconditional
// resolve.

const _url = 'https://example.supabase.co';
const _owner = 'uid-a';

/// A scripted native slot: the owner's generation counter disagrees until a
/// repair, and a read can be held open.
class _Native {
  bool mismatch = true;
  int reads = 0;
  Completer<void>? held;
  Completer<void>? release;
  final reached = Completer<void>();

  NativeEgressSlot get slot => NativeEgressSlot(
        read: (owner) async {
          reads++;
          final hold = held;
          if (hold != null) {
            held = null;
            release = hold;
            reached.complete();
            await hold.future;
          }
          if (owner.isNotEmpty && mismatch) {
            throw const FormatException(
                'native_egress_uncertain:owner_generation_mismatch');
          }
          if (owner.isEmpty) return null;
          return const CloudEgressRecord(
              state: EgressState.on,
              ownerUid: _owner,
              transitionGeneration: 1,
              reservedVersion: 1);
        },
        write: (_) async {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  late TestEgress egress;
  late F2Fixture f;
  late DriftUserSettingsRepository repo;
  var session = true;
  var repairs = 0;
  final reached = <http.BaseRequest>[];
  late GatedHttpClient transport;

  CaptureDeviceRegistrationService service({
    bool Function()? withSession,
    Future<String?> Function()? owner,
    Future<bool> Function(String uid)? repair,
    bool Function()? isCurrentScope,
  }) =>
      CaptureDeviceRegistrationService(
        settingsRepository: repo,
        gate: egress.gate,
        isIos: () => true,
        isAndroid: () => false,
        revokeAtSwitchOff: false,
        readSession: () => (withSession ?? () => session)()
            ? (uid: _owner, jwt: 'jwt')
            : null,
        readReplicaOwnerUid: owner ?? () async => _owner,
        repairOwnerGeneration: repair ??
            (uid) async {
              repairs++;
              native.mismatch = false;
              return true;
            },
        isCurrentScope: isCurrentScope,
      );

  setUp(() async {
    session = true;
    repairs = 0;
    reached.clear();
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
    native = _Native();
    egress = TestEgress(
        resolved: false, seedOn: true, native: native.slot, supabaseUrl: _url)
      ..install();
    egress.gate.configureSessionUsable(() => session);
    transport = GatedHttpClient(MockClient((request) async {
      reached.add(request);
      return http.Response('{}', 200);
    }));
    f = await F2Fixture.create();
    await f.host.lock();
    repo = DriftUserSettingsRepository(f.host.current!.database);
    expect(egress.gate.isResolved, isFalse);
  });
  tearDown(() async {
    await f.dispose();
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
  });

  Future<Object?> signIn() async {
    try {
      await egress.gate.runAccountControl(
          AccountControlOp.signIn,
          () => transport.post(
              Uri.parse('$_url/auth/v1/token?grant_type=id_token')));
      return null;
    } catch (e) {
      return e;
    }
  }

  Future<void> expectOrdinaryEgressDenied() async {
    final before = reached.length;
    for (final r in [
      () => transport.get(Uri.parse('$_url/rest/v1/transactions')),
      () => transport.post(
          Uri.parse('$_url/auth/v1/token?grant_type=refresh_token')),
      () => transport.post(Uri.parse('$_url/functions/v1/parse-sms')),
    ]) {
      await expectLater(r(), throwsA(isA<EgressDeniedException>()));
    }
    // Inside the sign-in allowance anything off the allowlist stays denied.
    await egress.gate.runAccountControl(AccountControlOp.signIn, () async {
      for (final r in [
        () => transport.get(Uri.parse('$_url/rest/v1/transactions')),
        () => transport.post(
            Uri.parse('$_url/auth/v1/token?grant_type=refresh_token')),
        () => transport.post(Uri.parse('$_url/functions/v1/parse-sms')),
      ]) {
        await expectLater(r(), throwsA(isA<EgressDeniedException>()));
      }
    });
    expect(reached.length, before, reason: 'nothing reached the network');
    expect(await egress.gate.permits(), isFalse);
  }

  test('session lost during the native read: the current owner resolves '
      'restrictively, no repair, sign-in is admitted', () async {
    native.held = Completer<void>();
    final running = service().resolvePendingDisable();
    await native.reached.future;
    session = false;
    native.release!.complete();
    await running;
    expect(egress.gate.isResolved, isTrue);
    expect(repairs, 0);
    expect(ConsentAuthority.egressFrozen, isTrue);
    expect(ConsentAuthority.egressFreezeTag, 'init_lifetime_lost');
    expect(await signIn(), isNull);
    expect(reached.map((r) => r.url.path), ['/auth/v1/token']);
    await expectOrdinaryEgressDenied();
  });

  test('session lost after the repair committed, before its reply: one repair, '
      'no stale thaw, resolved restrictively', () async {
    final s = service(repair: (uid) async {
      repairs++;
      native.mismatch = false; // the native side is consistent now
      session = false; // ... and the session vanishes before the reply
      return true;
    });
    await s.resolvePendingDisable();
    expect(repairs, 1);
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFrozen, isTrue,
        reason: 'a stale attempt never judges the repaired state');
    expect(ConsentAuthority.egressFreezeTag, 'init_lifetime_lost');
    expect(await signIn(), isNull);
    await expectOrdinaryEgressDenied();
  });

  test('session already absent: the repair is skipped and sign-in is not '
      'refused as unresolved', () async {
    session = false;
    await service().resolvePendingDisable();
    expect(repairs, 0);
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFreezeTag,
        'reconcile_uncertain:native:owner_generation_mismatch');
    expect(await signIn(), isNull);
    await expectOrdinaryEgressDenied();
  });

  test('a repair refused (null / exception) resolves restrictively', () async {
    for (final refuse in <Future<bool> Function(String)>[
      (uid) async => false,
      (uid) async => throw StateError('native'),
    ]) {
      ConsentAuthority.egressFrozen = false;
      ConsentAuthority.egressFreezeTag = '';
      egress = TestEgress(
          resolved: false, seedOn: true, native: native.slot, supabaseUrl: _url)
        ..install();
      egress.gate.configureSessionUsable(() => session);
      await service(repair: refuse).resolvePendingDisable();
      expect(egress.gate.isResolved, isTrue);
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(ConsentAuthority.egressFreezeTag, startsWith('reconcile_'));
      await expectOrdinaryEgressDenied();
    }
  });

  test('scope A superseded by scope B during reconciliation: A resolves '
      'nothing and keeps B\'s freeze; B resolves for itself', () async {
    native.mismatch = false;
    ConsentAuthority.freeze('prior_owner_withdrawal');
    final tokenA = egress.gate.beginResolution();
    native.held = Completer<void>();
    final a = service().resolvePendingDisable(resolution: tokenA);
    await native.reached.future;
    // B (a signed-out successor) starts its initialization.
    final tokenB = egress.gate.beginResolution();
    native.release!.complete();
    await a;
    expect(egress.gate.isResolved, isFalse, reason: 'A must not resolve B');
    expect(ConsentAuthority.egressFrozen, isTrue,
        reason: 'A must not thaw for B');
    expect(ConsentAuthority.egressFreezeTag, 'prior_owner_withdrawal');
    expect(egress.gate.markResolved(tokenA), isFalse);

    session = false;
    await service(owner: () async => null).resolvePendingDisable(
        resolution: tokenB);
    expect(egress.gate.isResolved, isTrue);
  });

  test('a recoverable failure (session read throws) resolves restrictively',
      () async {
    final s = CaptureDeviceRegistrationService(
      settingsRepository: repo,
      gate: egress.gate,
      readSession: () => throw StateError('session'),
      readReplicaOwnerUid: () async => _owner,
    );
    await s.resolvePendingDisable();
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFrozen, isTrue);
    expect(ConsentAuthority.egressFreezeTag, 'init_throw:StateError');
  });

  test('a Cloud-OFF transition in flight: the initialization retains the '
      'freeze and still resolves', () async {
    native.mismatch = false;
    final commit = Completer<void>();
    final disable = service()
        .disableCloud(commitLocalOff: () => commit.future)
        .then<void>((_) {}, onError: (Object _) {});
    expect(ConsentAuthority.egressFreezeTag, 'disable');
    await service().resolvePendingDisable();
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFrozen, isTrue);
    expect(ConsentAuthority.egressFreezeTag, 'disable');
    expect(await egress.gate.permits(), isFalse);
    commit.complete();
    await disable;
  });

  test('the initialization is stale at entry (epoch advanced): restrictive '
      'resolution, no reads', () async {
    final s = service();
    egress.gate.advanceEpoch();
    await s.resolvePendingDisable();
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFreezeTag, 'init_stale');
  });

  test('a verified clean reconciliation still resolves without a freeze',
      () async {
    native.mismatch = false;
    await service().resolvePendingDisable();
    expect(egress.gate.isResolved, isTrue);
    expect(ConsentAuthority.egressFrozen, isFalse);
  });

  // Admission recovery: the same-uid writable scope was re-admitted (sign-in)
  // while egress is frozen and nothing re-initialized it.
  group('reconcileAfterAdmission', () {
    var live = true;
    var scopeCurrent = true;

    AdmissionAuthority authority([String uid = _owner]) =>
        AdmissionAuthority(uid, () => live);

    Future<void> admit(CaptureDeviceRegistrationService s,
            {String uid = _owner}) =>
        s.reconcileAfterAdmission(
            authority: authority(uid), isCurrentScope: () => scopeCurrent);

    setUp(() {
      live = true;
      scopeCurrent = true;
      // A bootstrapped process: resolved, restrictively frozen by startup.
      egress.gate.markResolved(egress.gate.beginResolution());
      ConsentAuthority.freeze('startup_uncertain:native:owner_generation_mismatch');
    });

    test('epoch advanced after construction, then valid authority: one repair, '
        'verified reread, thaw, permits', () async {
      await repo.saveSettings((await repo.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));
      final s = service();
      egress.gate.advanceEpoch();
      await admit(s);
      expect(repairs, 1);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(await egress.gate.permits(), isTrue);
    });

    test('a refused or throwing repair leaves ordinary egress denied',
        () async {
      for (final refuse in <Future<bool> Function(String)>[
        (uid) async => false,
        (uid) async => throw StateError('native'),
      ]) {
        ConsentAuthority.freeze('startup_uncertain:x');
        await admit(service(repair: refuse));
        expect(ConsentAuthority.egressFrozen, isTrue);
        await expectOrdinaryEgressDenied();
      }
    });

    test('authority revoked during the native read: no repair, no thaw',
        () async {
      native.held = Completer<void>();
      final running = admit(service());
      await native.reached.future;
      live = false;
      native.release!.complete();
      await running;
      expect(repairs, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
    });

    test('authority revoked after the repair committed: no thaw', () async {
      await admit(service(repair: (uid) async {
        repairs++;
        native.mismatch = false;
        live = false;
        return true;
      }));
      expect(repairs, 1);
      expect(ConsentAuthority.egressFrozen, isTrue);
    });

    test('token superseded with the same epoch: the old attempt does not '
        'continue or thaw', () async {
      native.held = Completer<void>();
      final running = admit(service());
      await native.reached.future;
      egress.gate.beginResolution(); // a successor attempt, epoch unchanged
      native.release!.complete();
      await running;
      expect(repairs, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(ConsentAuthority.egressFreezeTag,
          'startup_uncertain:native:owner_generation_mismatch');
    });

    test('token superseded during pending-disable recovery: no internal '
        'completion, record stays DISABLING, freeze untouched', () async {
      const disabling = '{"v":1,"records":{"$_owner":'
          '{"state":"DISABLING","ownerUid":"$_owner",'
          '"transitionGeneration":2,"reservedVersion":1}}}';
      egress = TestEgress(resolved: false, supabaseUrl: _url)..install();
      egress.secure.value = disabling;
      egress.file.value = disabling;
      egress.gate.markResolved(egress.gate.beginResolution());
      ConsentAuthority.freeze('x');
      final s = service(owner: () async {
        egress.gate.beginResolution(); // superseded before the record is judged
        return _owner;
      });
      await admit(s);
      expect(ConsentAuthority.egressFreezeTag, 'x');
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(egress.secure.value, disabling);
      expect(egress.secure.writes, 0);
    });

    test('a disable in flight at entry: nothing is repaired or thawed',
        () async {
      final commit = Completer<void>();
      final disable = service(
              repair: (uid) async => false)
          .disableCloud(commitLocalOff: () => commit.future)
          .then<void>((_) {}, onError: (Object _) {});
      await admit(service());
      expect(repairs, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
      commit.complete();
      await disable;
    });

    test('a disable started during the held read makes the recovery stale',
        () async {
      native.held = Completer<void>();
      final running = admit(service());
      await native.reached.future;
      final commit = Completer<void>();
      final disable = service()
          .disableCloud(commitLocalOff: () => commit.future)
          .then<void>((_) {}, onError: (Object _) {});
      native.release!.complete();
      await running;
      expect(repairs, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
      commit.complete();
      await disable;
    });

    test('wrong uid, other replica marker, disposed service, stale scope or '
        'absent session mutate nothing', () async {
      await admit(service(), uid: 'uid-b');
      await admit(service(owner: () async => 'uid-b'));
      final disposed = service()..dispose();
      await admit(disposed);
      scopeCurrent = false;
      await admit(service());
      scopeCurrent = true;
      session = false;
      await admit(service());
      expect(repairs, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
    });

    test('an unresolved gate is not this hook\'s job', () async {
      egress = TestEgress(
          resolved: false, seedOn: true, native: native.slot, supabaseUrl: _url)
        ..install();
      ConsentAuthority.freeze('x');
      await admit(service());
      expect(repairs, 0);
      expect(egress.gate.isResolved, isFalse);
    });

    test('healthy, unfrozen reuse runs no reconciliation', () async {
      ConsentAuthority.egressFrozen = false;
      await admit(service());
      expect(native.reads, 0);
      expect(repairs, 0);
    });

    for (final fixture in ['off', 'missing', 'pending_enable', 'disabling']) {
      test('$fixture stays restrictive and never revokes', () async {
        egress = TestEgress(resolved: false, supabaseUrl: _url)..install();
        egress.gate.markResolved(egress.gate.beginResolution());
        String rec(String state) => '{"v":1,"records":{"$_owner":'
            '{"state":"$state","ownerUid":"$_owner",'
            '"transitionGeneration":2,"reservedVersion":1}}}';
        if (fixture == 'off' || fixture == 'disabling') {
          final body = rec(fixture == 'off' ? 'OFF' : 'DISABLING');
          egress.secure.value = body;
          egress.file.value = body;
        } else if (fixture == 'pending_enable') {
          egress.secure.value = rec('ON');
          egress.file.value = rec('ON');
          egress.gate.freezeEnable(_owner);
        }
        ConsentAuthority.freeze('x');
        await admit(service());
        expect(await egress.gate.permits(), isFalse);
        if (fixture == 'pending_enable') {
          expect(ConsentAuthority.egressFrozen, isTrue);
        }
        expect(reached, isEmpty, reason: 'no revoke, no request');
      });
    }
  });
}
