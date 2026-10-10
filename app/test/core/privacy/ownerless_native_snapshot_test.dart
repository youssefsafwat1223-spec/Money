import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const healthy = {'status': 'ownerless', 'contractVersion': 1,
    'ownerEpoch': 0, 'ownerGeneration': 0};
  late Object? response;
  late List<MethodCall> calls;
  late TestEgress egress;

  setUp(() {
    NativeCaptureBridge.debugTreatHostAsNative = true;
    ConsentAuthority.egressFrozen = false;
    response = healthy;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (response is PlatformException) throw response! as PlatformException;
      return response;
    });
    egress = TestEgress(native: NativeEgressSlot.platformDefault(), resolved: false,
      supabaseUrl: 'http://127.0.0.1:54321').install()..owner = null;
  });
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    ConsentAuthority.egressFrozen = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> reconcile() async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    try {
      final repo = DriftUserSettingsRepository(db);
      await CaptureDeviceRegistrationService(
        settingsRepository: repo, gate: egress.gate,
        isIos: () => true, isAndroid: () => false,
        readReplicaOwnerUid: () async => egress.owner,
        readSession: () => null,
      ).resolvePendingDisable();
      expect((await repo.getSettings()).cloudProcessingEnabled, false);
    } finally {
      await db.close();
    }
  }

  test('A verified fresh ownerless snapshot allows explicit auth and keeps Cloud OFF', () async {
    await reconcile();
    expect(ConsentAuthority.egressFrozen, false);
    expect(await egress.gate.permits(), false);
    final seen = <Uri>[];
    final client = GatedHttpClient(MockClient((request) async {
      seen.add(request.url);
      return http.Response('{}', 200);
    }));
    await egress.gate.runAccountControl(AccountControlOp.signIn, () => client.post(
      Uri.parse('http://127.0.0.1:54321/auth/v1/token?grant_type=id_token')));
    expect(seen, hasLength(1));
    await expectLater(client.get(Uri.parse('http://127.0.0.1:54321/rest/v1/items')),
      throwsA(isA<EgressDeniedException>()));
    expect(seen, hasLength(1));
    expect(calls.every((call) => call.method == 'getCloudEgressState'), true);
    expect(egress.secure.writes + egress.file.writes, 0);
  });

  test('B verified ownerless after Remove Data never projects historical OFF into admission', () async {
    response = {...healthy, 'ownerEpoch': 3, 'ownerGeneration': 1};
    await reconcile();
    expect(ConsentAuthority.egressFrozen, false);
    expect((await egress.gate.view()).record, null);
    expect(await egress.gate.permits(), false);
  });

  for (final entry in <String, Object?>{
    'C known removal barrier': {'status': 'uncertain'},
    'D unknown removal barrier': {'status': 'uncertain'},
    'E missing evidence': {'status': 'ownerless'},
    'E old unset is not ownerless proof': {'status': 'unset'},
    'E negative epoch': {...healthy, 'ownerEpoch': -1},
    'E wrong generation type': {...healthy, 'ownerGeneration': '0'},
    'E unknown contract': {...healthy, 'contractVersion': 2},
    'E noninteger contract': {...healthy, 'contractVersion': 1.0},
    'E contradictory ownership': {...healthy, 'ownerUid': 'uid-a'},
    'E malformed': 'invalid',
    'F read or transport failure': PlatformException(code: 'queue_error'),
    'G owned response for ownerless query': {'status': 'record', 'state': 'ON',
      'ownerUid': 'uid-a', 'transitionGeneration': 1, 'reservedVersion': 1},
  }.entries) {
    test('${entry.key} fails closed', () async {
      response = entry.value;
      await reconcile();
      expect(ConsentAuthority.egressFrozen, true);
      expect(await egress.gate.permits(), false);
    });
  }

  test('G nonempty owner rejects another UID and ownerless evidence', () async {
    egress.owner = 'uid-a';
    response = {'status': 'record', 'state': 'ON', 'ownerUid': 'uid-b',
      'transitionGeneration': 1, 'reservedVersion': 1};
    expect((await egress.gate.view()).uncertain, true);
    response = healthy;
    expect((await egress.gate.view()).uncertain, true);
  });

  test('H valid owned ON retains the original automatic consent gate', () async {
    egress.owner = 'uid-a';
    response = {'status': 'record', 'state': 'ON', 'ownerUid': 'uid-a',
      'transitionGeneration': 1, 'reservedVersion': 1};
    egress.gate.markResolved();
    expect(await egress.gate.permits(), true);
    response = {...response! as Map, 'state': 'OFF'};
    expect(await egress.gate.permits(), false);
  });
}
