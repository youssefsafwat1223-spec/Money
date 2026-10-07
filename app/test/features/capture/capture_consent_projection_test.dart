import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

// WP-6 — the capture-owner gate (manifest §4.2/§4.6): the owner is published
// only after link_capture_device(consent) succeeded, the per-owner mirror
// follows the replica's own versioned consent, and a revocation reaches the
// device first and the server through set_capture_consent.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

typedef _Consent = ({bool cloud, bool ai, int version});

class _Backend extends CaptureBackendClient {
  _Backend() : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  int registers = 0;
  @override
  Future<String> registerDevice(
      {required String installId, String platform = 'ios'}) async {
    registers++;
    return 'device-secret';
  }

  @override
  Future<void> unlinkDevice(
      {required String installId, required String deviceSecret}) async {}
}

/// Records every call into the shared [events] log so ordering is assertable.
class _ConsentServer extends CaptureConsentClient {
  _ConsentServer(this.events)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> events;
  final links = <_Consent>[];
  final sets = <_Consent>[];
  Object? linkError;
  Object? setError;

  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    events.add('link');
    if (linkError != null) throw linkError!;
    links.add((cloud: cloud, ai: ai, version: version));
  }

  @override
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    events.add('set');
    if (setError != null) throw setError!;
    sets.add((cloud: cloud, ai: ai, version: version));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late List<String> events;
  late _ConsentServer server;
  late _Backend backend;
  late List<(String, _Consent)> mirrors;
  late List<String> published;
  CaptureSession? session;
  String? replicaOwner;

  CaptureDeviceRegistrationService service() =>
      CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: server,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
        }) async {},
        loadApnsToken: () async => null,
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        }) async {
          events.add('mirror');
          mirrors.add((uid, (cloud: cloud, ai: ai, version: version)));
        },
        publishOwner: (uid) async {
          events.add('publish');
          published.add(uid);
        },
      );

  Future<UserSettingsEntity> save(
      {ConsentState? cloud, ConsentState? ai}) async {
    final s = await repo.getSettings();
    return repo.saveSettings(
        s.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    events = [];
    server = _ConsentServer(events);
    backend = _Backend();
    mirrors = [];
    published = [];
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
  });
  tearDown(() async => db.close());

  group('owner publication is gated on link_capture_device(consent)', () {
    test('publishes only AFTER the link succeeded, and writes the mirror first',
        () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);

      await service().linkToCurrentUser();

      expect(events, ['link', 'mirror', 'publish']);
      expect(server.links.single, (cloud: true, ai: true, version: 1));
      expect(mirrors.single, ('uid-a', (cloud: true, ai: true, version: 1)));
      expect(published, ['uid-a']);
    });

    test('the owner is NOT published (and no mirror written) when link fails',
        () async {
      await save(cloud: ConsentState.accepted);
      server.linkError = const CaptureBackendException('link_device_failed_500');

      await service().linkToCurrentUser();

      expect(events, ['link']);
      expect(published, isEmpty);
      expect(mirrors, isEmpty);
    });

    test('offline: a failed link then a later success publishes exactly then',
        () async {
      final s = service();
      server.linkError = const CaptureBackendException('offline');
      await s.linkToCurrentUser();
      expect(published, isEmpty);

      server.linkError = null;
      await s.linkToCurrentUser();
      expect(published, ['uid-a']);
    });

    test('no session, or a session that is not the admitted replica: no link',
        () async {
      session = null;
      await service().linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'jwt-b'); // replica belongs to uid-a
      await service().linkToCurrentUser();
      replicaOwner = null;
      session = (uid: 'uid-a', jwt: 'jwt-a');
      await service().linkToCurrentUser();

      expect(events, isEmpty);
      expect(published, isEmpty);
    });

    test('cloud OFF and AI OFF are linked too, as explicit OFF flags',
        () async {
      await service().linkToCurrentUser();
      expect(server.links.single, (cloud: false, ai: false, version: 0));
      expect(mirrors.single.$2, (cloud: false, ai: false, version: 0));
      expect(published, ['uid-a']);
    });

    test('AI is never projected without Cloud (cloud is the master gate)',
        () async {
      await save(cloud: ConsentState.declined, ai: ConsentState.accepted);
      await service().linkToCurrentUser();
      expect(server.links.single.cloud, isFalse);
      expect(server.links.single.ai, isFalse);
    });

    test('a repeat admission with nothing changed does not call the server',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      await s.linkToCurrentUser();
      expect(server.links, hasLength(1));
      expect(published, ['uid-a', 'uid-a'], reason: 'publish is idempotent');
    });

    test('a session lost during the link round trip publishes nothing',
        () async {
      await save(cloud: ConsentState.accepted);
      final slow = _SwitchingServer(events, () => session = null);
      final s = CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: slow,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        }) async =>
            events.add('mirror'),
        publishOwner: (uid) async => events.add('publish'),
      );
      await s.linkToCurrentUser();
      expect(events, ['link']);
    });
  });

  group('a consent change is projected with a version that only grows', () {
    Future<CaptureDeviceRegistrationService> linked() async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      events.clear();
      mirrors.clear();
      return s;
    }

    test('a revoke updates the mirror FIRST and then the server', () async {
      final s = await linked();
      await save(ai: ConsentState.declined);

      await s.syncBackendState();

      expect(events, ['mirror', 'set', 'mirror']);
      expect(mirrors.first.$2, (cloud: true, ai: false, version: 2),
          reason: 'restrictive mirror before the network call');
      expect(server.sets.single, (cloud: true, ai: false, version: 2));
      expect(mirrors.last.$2, (cloud: true, ai: false, version: 2));
    });

    test('a failed revoke still stops the device and is retried', () async {
      final s = await linked();
      await save(cloud: ConsentState.declined);
      server.setError = const CaptureBackendException('offline');

      await s.syncBackendState();
      expect(mirrors.single.$2, (cloud: false, ai: false, version: 2));
      expect(server.sets, isEmpty);

      server.setError = null;
      events.clear();
      await s.syncBackendState();
      expect(server.sets.single, (cloud: false, ai: false, version: 2),
          reason: 'the same absolute state is retried');
    });

    test('a grant widens the mirror only after the server accepted it',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      events.clear();
      mirrors.clear();

      await save(ai: ConsentState.accepted);
      server.setError = const CaptureBackendException('offline');
      await s.syncBackendState();
      expect(mirrors.single.$2.ai, isFalse,
          reason: 'an unacknowledged grant is not mirrored');

      server.setError = null;
      await s.syncBackendState();
      expect(mirrors.last.$2, (cloud: true, ai: true, version: 2));
    });

    test('versions sent to the server never decrease', () async {
      final s = await linked(); // link at version 1
      final sent = <int>[server.links.single.version];
      for (final step in [
        () => save(ai: ConsentState.declined),
        () => save(cloud: ConsentState.declined),
        () => save(cloud: ConsentState.accepted),
        () => save(ai: ConsentState.accepted),
      ]) {
        await step();
        await s.syncBackendState();
        sent.add(server.sets.last.version);
      }
      expect(sent, [1, 2, 3, 4, 5]);
      for (var i = 1; i < sent.length; i++) {
        expect(sent[i], greaterThan(sent[i - 1]));
      }
    });

    test('an unchanged state is not re-sent', () async {
      final s = await linked();
      await s.syncBackendState();
      expect(server.sets, isEmpty);
    });

    test('sign-out unlink forgets the acknowledgement: the next admission '
        're-links', () async {
      final s = await linked();
      await s.unlinkCurrentDevice();
      await s.linkToCurrentUser();
      expect(server.links, hasLength(2));
    });
  });

  group('consent never crosses users', () {
    test("uid A's acknowledged consent is not reused for uid B", () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await service().linkToCurrentUser(); // A linked at (true,true,1)

      // B signs in on the same install; B's replica is a different database
      // whose consent is unset.
      final dbB = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(dbB.close);
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      final b = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(dbB),
        client: backend,
        consentClient: server,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        }) async =>
            mirrors.add((uid, (cloud: cloud, ai: ai, version: version))),
        publishOwner: (uid) async => published.add(uid),
      );
      mirrors.clear();
      published.clear();

      await b.linkToCurrentUser();

      expect(server.links.last, (cloud: false, ai: false, version: 0),
          reason: "B is linked with B's own (unset) consent");
      expect(mirrors.single, ('uid-b', (cloud: false, ai: false, version: 0)));
      expect(published, ['uid-b']);
    });
  });
}

class _SwitchingServer extends _ConsentServer {
  _SwitchingServer(super.events, this.onLink);
  final void Function() onLink;
  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    await super.link(
        installId: installId,
        deviceSecret: deviceSecret,
        jwt: jwt,
        cloud: cloud,
        ai: ai,
        version: version);
    onLink(); // the user signs out while the request is in flight
  }
}
