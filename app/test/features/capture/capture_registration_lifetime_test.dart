import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/egress_test_support.dart';

class RecordingSettings extends DriftUserSettingsRepository {
  RecordingSettings(super.db);
  int reads = 0;
  int writes = 0;
  Completer<void>? reached;
  Completer<void>? release;
  bool failRead = false;

  void pause() {
    reached = Completer<void>();
    release = Completer<void>();
  }
  @override
  Future<UserSettingsEntity> getSettings() async {
    reads++;
    final settings = await super.getSettings();
    final hold = release;
    if (hold != null && !reached!.isCompleted) {
      reached!.complete();
      await hold.future;
      release = null;
    }
    if (failRead) throw StateError('settings sentinel');
    return settings;
  }
  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
    writes++;
    return super.saveSettings(settings);
  }
}

class NoNetworkClient implements CaptureBackendClient {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('unexpected network operation');
  }
}

class PausedGenerationGate extends CloudEgressGate {
  PausedGenerationGate(CloudEgressStore store)
      : super(store: store, activeOwner: () async => 'uid-x', resolved: true);
  bool armed = false;
  final reached = Completer<void>();
  final releaseRead = Completer<void>();
  @override
  Future<EgressView> view({String? owner}) async {
    final result = await super.view(owner: owner);
    if (armed) {
      armed = false;
      reached.complete();
      await releaseRead.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('retained signed-out service rejects closed DB after real admission',
      () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.host.lock();
      final oldDb = f.host.current!.database;
      final settings = RecordingSettings(oldDb);
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: egress.gate,
        isIos: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt-x'),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
      await f.session.setIdentity(method: 'google', userId: 'uid-x');
      expect(oldDb.lifecycleState, DatabaseLifecycleState.closed);
      final from = f.storage.attempts.length;
      ConsentAuthority.egressFrozen = false;
      await service.linkToCurrentUser();
      expect(ConsentAuthority.egressFrozen, isFalse,
          reason: 'stale settings failure must not freeze the admitted scope');
      expect(settings.reads, 0,
          reason: 'a retired service must not attempt SQL');
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(f.host.activeUid, 'uid-x');
    } finally {
      await f.dispose();
      ConsentAuthority.egressFrozen = false;
    }
  });
  for (final transition in ['Remove Data', 'sign-out', 'X to Y', 'same UID admission']) {
    test('deferred callback after $transition has no side effects', () async {
      final egress = TestEgress().install();
      final f = await F2Fixture.create();
      try {
        await f.signIn('uid-x');
        final db = f.host.current!.database;
        final settings = RecordingSettings(db)..pause();
        final network = NoNetworkClient();
        var publishes = 0;
        final service = CaptureDeviceRegistrationService(
          settingsRepository: settings,
          gate: egress.gate,
          client: network,
          isIos: () => true,
          isBackendConfigured: () => true,
          readSession: () => f.host.activeUid == null ? null :
              (uid: f.host.activeUid!, jwt: 'jwt'),
          captureWorkAuthority: f.session.captureLocalWorkAuthority,
          isCurrentScope: () => identical(f.host.current?.database, db),
          readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
          readOwnerEpoch: () async => 0,
          publishOwner: ({required uid, required cloud, required ai,
            required version, required expectedEpoch, transitionGeneration}) async {
            publishes++;
          },
        );
        ConsentAuthority.egressFrozen = false;
        final pending = service.linkToCurrentUser();
        await settings.reached!.future;
        switch (transition) {
          case 'Remove Data': await f.session.removeDataFromDevice();
          case 'sign-out': await f.session.signOut();
          case 'X to Y': await f.signIn('uid-y');
          case 'same UID admission': await f.signIn('uid-x');
        }
        final from = f.storage.attempts.length;
        ConsentAuthority.egressFrozen = false;
        settings.failRead = true;
        settings.release!.complete();
        await pending;
        expect(settings.reads, 1);
        expect(settings.writes, 0);
        expect(network.calls, 0);
        expect(publishes, 0);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(f.storage.attempts.skip(from), isEmpty);
        if (transition == 'Remove Data') {
          expect(await f.artifactsOf('uid-x'), isEmpty);
          expect(await f.flow.revokedUids(), contains('uid-x'));
        }
      } finally {
        await f.dispose();
        ConsentAuthority.egressFrozen = false;
      }
    });
  }

  test('current committed scope publishes locally with Cloud OFF and no network', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final db = f.host.current!.database;
      final network = NoNetworkClient();
      var publishes = 0;
      final service = CaptureDeviceRegistrationService(
        settingsRepository: RecordingSettings(db),
        gate: egress.gate,
        client: network,
        isIos: () => true,
        isBackendConfigured: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () => identical(f.host.current?.database, db),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        readOwnerEpoch: () async => 0,
        publishOwner: ({required uid, required cloud, required ai,
          required version, required expectedEpoch, transitionGeneration}) async {
          expect(uid, 'uid-x'); expect(cloud, isFalse); expect(ai, isFalse);
          publishes++;
        },
      );
      final from = f.storage.attempts.length;
      ConsentAuthority.egressFrozen = false;
      await service.linkToCurrentUser();
      expect(publishes, 1);
      expect(network.calls, 0);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:') || a.startsWith('delete:')), isEmpty);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('CURRENT scope settings StateError still freezes egress', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final settings = RecordingSettings(f.host.current!.database)..failRead = true;
      final network = NoNetworkClient();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate, client: network,
        isIos: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
      ConsentAuthority.egressFrozen = false;
      await service.linkToCurrentUser();
      expect(settings.reads, 1);
      expect(settings.writes, 0);
      expect(network.calls, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('ProviderScope remount retires a service while the same DB stays open', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final db = f.host.current!.database;
      final oldContainer = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      final old = oldContainer.read(captureDeviceRegistrationServiceProvider);
      oldContainer.dispose();
      final current = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      try {
        expect(current.read(captureDeviceRegistrationServiceProvider), isNot(same(old)));
        ConsentAuthority.egressFrozen = false;
        await old.resolvePendingDisable();
        expect(db.lifecycleState, DatabaseLifecycleState.open);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(egress.secure.writes, 0);
      } finally { current.dispose(); }
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('retired open bootstrap initializer cannot clear a newer freeze', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.host.lock();
      final settings = RecordingSettings(f.host.current!.database);
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate,
        readSession: () => null, readReplicaOwnerUid: () async => null,
      );
      egress.gate.advanceEpoch();
      ConsentAuthority.egressFrozen = true;
      await service.resolvePendingDisable();
      expect(settings.reads, 0);
      expect(settings.writes, 0);
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(egress.secure.writes, 0);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('initializer becomes stale during a settings await without freezing new scope', () async {
    final egress = TestEgress(resolved: false).install();
    final f = await F2Fixture.create();
    try {
      await f.host.lock();
      final settings = RecordingSettings(f.host.current!.database)..pause();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate,
        readSession: () => null, readReplicaOwnerUid: () async => null,
      );
      final pending = service.resolvePendingDisable();
      await settings.reached!.future;
      egress.gate.advanceEpoch();
      ConsentAuthority.egressFrozen = false;
      settings.failRead = true;
      settings.release!.complete();
      await pending;
      expect(settings.writes, 0);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(egress.secure.writes, 0);
      expect(egress.gate.isResolved, isFalse);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('concurrent generations: stale settings failure cannot freeze valid Y', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final oldDb = f.host.current!.database;
      final oldSettings = RecordingSettings(oldDb)..pause();
      var publishes = 0;
      CaptureDeviceRegistrationService build(RecordingSettings settings, AppDatabase db) =>
          CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate, isIos: () => true,
        readSession: () => (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () => identical(f.host.current?.database, db),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        readOwnerEpoch: () async => 0,
        publishOwner: ({required uid, required cloud, required ai,
            required version, required expectedEpoch, transitionGeneration}) async {
          expect(uid, 'uid-y'); expect(cloud, isFalse); publishes++;
        },
      );
      final old = build(oldSettings, oldDb);
      ConsentAuthority.egressFrozen = false;
      final pending = old.linkToCurrentUser();
      await oldSettings.reached!.future;
      await f.signIn('uid-y');
      final currentDb = f.host.current!.database;
      final current = build(RecordingSettings(currentDb), currentDb);
      ConsentAuthority.egressFrozen = false;
      await current.linkToCurrentUser();
      final from = f.storage.attempts.length;
      oldSettings.failRead = true;
      oldSettings.release!.complete();
      await pending;
      expect(publishes, 1);
      expect(oldSettings.writes, 0);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(f.host.activeUid, 'uid-y');
      expect(f.storage.attempts.skip(from), isEmpty);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('service disposal during reconciliation rejects writes on still-open DB', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final db = f.host.current!.database;
      final settings = RecordingSettings(db)..pause();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate, isIos: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
      ConsentAuthority.egressFrozen = false;
      final pending = service.linkToCurrentUser();
      await settings.reached!.future;
      service.dispose();
      settings.failRead = true;
      settings.release!.complete();
      await pending;
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      expect(settings.writes, 0);
      expect(ConsentAuthority.egressFrozen, isFalse);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('bootstrap initialization reconciles before publication then committed link works', () async {
    final egress = TestEgress().install();
    CaptureDeviceRegistrationService? registration;
    late F2Fixture f;
    var publishes = 0;
    f = await F2Fixture.create(initialize: (db, uid) async {
      egress.gate.advanceEpoch();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: RecordingSettings(db), gate: egress.gate, isIos: () => true,
        readSession: () => uid == null ? null : (uid: uid, jwt: 'jwt'),
        captureWorkAuthority: () => f.session.captureLocalWorkAuthority(),
        isCurrentScope: () => identical(f.host.current?.database, db) && f.host.current?.uid == uid,
        readReplicaOwnerUid: () => f.session.readLocalDataOwnerUid(),
        readOwnerEpoch: () async => 0,
        publishOwner: ({required uid, required cloud, required ai,
            required version, required expectedEpoch, transitionGeneration}) async {
          expect(uid, 'uid-x'); publishes++;
        },
      );
      registration = service;
      await service.resolvePendingDisable();
      expect(ConsentAuthority.egressFrozen, isFalse);
      return const AccountScopeInit();
    });
    try {
      await f.signIn('uid-x');
      await registration!.linkToCurrentUser();
      expect(publishes, 1);
      expect(ConsentAuthority.egressFrozen, isFalse);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('late 401 after service disposal cannot rotate credentials or retry', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final db = f.host.current!.database;
      final repository = RecordingSettings(db);
      final settings = await repository.getSettings();
      await repository.saveSettings(settings.copyWith(cloudConsentState: ConsentState.accepted));
      await egress.gate.enable(owner: 'uid-x', reservedVersion: 1);
      await f.storage.write(key: 'qirsh_capture_device_secret', value: 'old-secret', options: const {});
      final reached = Completer<void>();
      final release = Completer<void>();
      var consentCalls = 0;
      final network = NoNetworkClient();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: repository, gate: egress.gate, client: network,
        consentClient: CaptureConsentClient(supabaseUrl: 'https://example.supabase.co', anonKey: 'anon',
          httpClient: MockClient((_) async {
            consentCalls++;
            reached.complete();
            await release.future;
            return http.Response('', 401);
          })),
        isIos: () => true, isBackendConfigured: () => true,
        loadInstallId: () async => 'install',
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        readOwnerEpoch: () async => 0,
      );
      ConsentAuthority.egressFrozen = false;
      final pending = service.linkToCurrentUser();
      await reached.future;
      service.dispose();
      final from = f.storage.attempts.length;
      final reads = repository.reads;
      release.complete();
      await pending;
      expect(consentCalls, 1);
      expect(network.calls, 0);
      expect(repository.reads, reads);
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(f.storage.data['qirsh_capture_device_secret'], 'old-secret');
      expect(ConsentAuthority.egressFrozen, isFalse);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  test('disable during mirror generation await cannot widen native consent', () async {
    final secure = MemorySlot();
    final file = MemorySlot();
    final gate = PausedGenerationGate(CloudEgressStore.forTesting(secure: secure, file: file));
    CloudEgressGate.instance = gate;
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final repository = RecordingSettings(f.host.current!.database);
      final settings = await repository.getSettings();
      final updated = await repository.saveSettings(settings.copyWith(cloudConsentState: ConsentState.accepted,
          aiConsentState: ConsentState.accepted));
      await gate.enable(owner: 'uid-x', reservedVersion: updated.consentVersion);
      await f.storage.write(key: 'qirsh_capture_device_secret', value: 'secret', options: const {});
      await f.storage.write(key: 'qirsh_capture_consent_ack', value: 'uid-x|1|1|0', options: const {});
      var mirrors = 0;
      final network = NoNetworkClient();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: repository, gate: gate, client: network,
        isIos: () => true, isBackendConfigured: () => true,
        loadInstallId: () async => 'install',
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        writeNativeBackendConfig: ({required cloudProcessingEnabled, required installId,
          deviceSecret, required backendUrl, required anonKey, required aiConsentGranted,
          ownerUid, transitionGeneration}) async { gate.armed = true; },
        writeConsentMirror: ({required uid, required cloud, required ai, required version,
          transitionGeneration}) async { mirrors++; },
      );
      ConsentAuthority.egressFrozen = false;
      final pending = service.syncNativeState();
      await gate.reached.future;
      gate.advanceEpoch();
      ConsentAuthority.egressFrozen = true;
      final from = f.storage.attempts.length;
      gate.releaseRead.complete();
      await pending;
      expect(mirrors, 0);
      expect(network.calls, 0);
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(ConsentAuthority.egressFrozen, isTrue);
    } finally { await f.dispose(); ConsentAuthority.egressFrozen = false; }
  });

  for (final completed in [false, true]) {
  test('fresh explicit onboarding admission publishes through actual session hook (completed=$completed)', () async {
    final egress = TestEgress().install();
    CaptureDeviceRegistrationService? registration;
    late F2Fixture f;
    Future<void>? linking;
    var publishes = 0;
    f = await F2Fixture.create(initialize: (db, uid) async {
      egress.gate.advanceEpoch();
      registration = CaptureDeviceRegistrationService(
        settingsRepository: RecordingSettings(db), gate: egress.gate, isIos: () => true,
        readSession: () => uid == null ? null : (uid: uid, jwt: 'jwt'),
        captureWorkAuthority: () => f.session.captureLocalWorkAuthority(),
        isCurrentScope: () => identical(f.host.current?.database, db) && f.host.current?.uid == uid,
        readReplicaOwnerUid: () => f.session.readLocalDataOwnerUid(),
        readOwnerEpoch: () async => 0,
        publishOwner: ({required uid, required cloud, required ai,
            required version, required expectedEpoch, transitionGeneration}) async { publishes++; },
      );
      await registration!.resolvePendingDisable();
      return const AccountScopeInit();
    });
    f.session.configureCaptureOwnerPublish((_, authority) async {
      linking = registration!.linkToCurrentUser(admissionAuthority: authority);
      await linking;
    });
    try {
      if (completed) {
        await f.signIn('uid-x');
        publishes = 0;
      }
      await f.session.setIdentity(method: 'google', userId: 'uid-x');
      await linking;
      expect(f.host.activeUid, 'uid-x');
      expect(publishes, 1, reason: 'the committed fresh onboarding scope must publish locally');
    } finally {
      f.session.configureCaptureOwnerPublish(null);
      await f.dispose(); ConsentAuthority.egressFrozen = false;
    }
  });

  }
  test('same DB new committed hook succeeds while old epoch callback is paused', () async {
    final egress = TestEgress().install();
    final f = await F2Fixture.create();
    try {
      await f.signIn('uid-x');
      final db = f.host.current!.database;
      final settings = RecordingSettings(db)..pause();
      var publishes = 0;
      final service = CaptureDeviceRegistrationService(
        settingsRepository: settings, gate: egress.gate, isIos: () => true,
        readSession: () => (uid: 'uid-x', jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () => identical(f.host.current?.database, db),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
        readOwnerEpoch: () async => 0,
        publishOwner: ({required uid, required cloud, required ai,
            required version, required expectedEpoch, transitionGeneration}) async { publishes++; },
      );
      ConsentAuthority.egressFrozen = false;
      final old = service.linkToCurrentUser();
      await settings.reached!.future;
      Future<void>? current;
      f.session.configureCaptureOwnerPublish((_, authority) async {
        current = service.linkToCurrentUser(admissionAuthority: authority);
        await current;
      });
      await f.session.setIdentity(method: 'google', userId: 'uid-x');
      await current;
      expect(f.host.current!.database, same(db));
      expect(publishes, 1);
      final from = f.storage.attempts.length;
      settings.failRead = true;
      settings.release!.complete();
      await old;
      expect(publishes, 1);
      expect(settings.writes, 0);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(f.storage.attempts.skip(from), isEmpty);
    } finally {
      f.session.configureCaptureOwnerPublish(null);
      await f.dispose(); ConsentAuthority.egressFrozen = false;
    }
  });

  for (final transition in ['Remove Data', 'sign-out', 'same UID admission', 'mismatched UID', 'missing authority']) {
    test('forwarded committed hook authority rejects after $transition', () async {
      final egress = TestEgress().install();
      final f = await F2Fixture.create();
      AdmissionAuthority? admitted;
      f.session.configureCaptureOwnerPublish((_, authority) async { admitted = authority; });
      try {
        await f.session.setIdentity(method: 'google', userId: 'uid-x');
        final oldAuthority = admitted!;
        final db = f.host.current!.database;
        final settings = RecordingSettings(db);
        final network = NoNetworkClient();
        var publishes = 0;
        final service = CaptureDeviceRegistrationService(
          settingsRepository: settings, gate: egress.gate, client: network, isIos: () => true,
          readSession: () => (uid: transition == 'mismatched UID' ? 'uid-y' : 'uid-x', jwt: 'jwt'),
          captureWorkAuthority: f.session.captureLocalWorkAuthority,
          isCurrentScope: () => identical(f.host.current?.database, db),
          readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
          publishOwner: ({required uid, required cloud, required ai,
              required version, required expectedEpoch, transitionGeneration}) async { publishes++; },
        );
        if (transition == 'Remove Data') await f.session.removeDataFromDevice();
        if (transition == 'sign-out') await f.session.signOut();
        if (transition == 'same UID admission') await f.session.setIdentity(method: 'google', userId: 'uid-x');
        final from = f.storage.attempts.length;
        ConsentAuthority.egressFrozen = false;
        await service.linkToCurrentUser(admissionAuthority:
            transition == 'missing authority' ? null : oldAuthority);
        expect(settings.reads, 0); expect(settings.writes, 0);
        expect(network.calls, 0); expect(publishes, 0);
        expect(ConsentAuthority.egressFrozen, isFalse);
        expect(f.storage.attempts.skip(from), isEmpty);
      } finally {
        f.session.configureCaptureOwnerPublish(null);
        await f.dispose(); ConsentAuthority.egressFrozen = false;
      }
    });
  }

}
