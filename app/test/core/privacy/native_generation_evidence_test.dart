import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';

const _owner = 'uid-x';
Map<String, Object?> _layer(String layer, String state, int generation,
        {bool retired = false}) =>
    {
      'layer': layer,
      'outcome': 'verified',
      'state': state,
      'transitionGeneration': generation,
      'reservedVersion': 1,
      if (retired) ...{
        'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'ownerGeneration': 4,
        'ownerEpoch': 5,
      },
    };
Object _inspection(List<Map<String, Object?>> egress) => {
      'contractVersion': 1,
      'operation': 'inspect',
      'status': 'noBarrier',
      'barrier': [
        {'layer': 'file', 'outcome': 'absent'},
        {'layer': 'keychain', 'outcome': 'absent'},
      ],
      'egress': egress,
    };
String _envelope(CloudEgressRecord record) => jsonEncode({
      'v': 1,
      'records': {_owner: record.toJson()},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late TestEgress rig;
  late Object? inspection;
  late List<MethodCall> nativeWrites;
  late bool rejectWrites;
  late Object? admission;

  setUp(() {
    NativeCaptureBridge.debugTreatHostAsNative = true;
    inspection = _inspection([
      _layer('file', 'OFF', 2),
      _layer('keychain', 'ON', 10),
    ]);
    nativeWrites = [];
    rejectWrites = false;
    admission = {
      'status': 'record', 'state': 'OFF', 'ownerUid': _owner,
      'transitionGeneration': 2, 'reservedVersion': 1,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCloudEgressState') {
        // The real admission merge returns restrictive g2 before checking
        // uncertainty, even when the other physical layer is ON g10/unreadable.
        return admission;
      }
      if (call.method == 'getCloudEgressPending') return inspection;
      if (call.method == 'setCloudEgressState') {
        nativeWrites.add(call);
        if (rejectWrites) throw PlatformException(code: 'stale_generation');
        return null;
      }
      throw StateError('unexpected native call ${call.method}');
    });
    rig = TestEgress(native: NativeEgressSlot.platformDefault())..owner = _owner;
    const off = CloudEgressRecord(state: EgressState.off, ownerUid: _owner,
        transitionGeneration: 2, reservedVersion: 1);
    rig.secure.value = _envelope(off);
    rig.file.value = _envelope(off);
  });
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final entry in ['disable', 'enable', 'align']) {
    Future<void> transition() async {
      if (entry == 'disable') {
        final result = await rig.gate.beginDisabling(
            owner: _owner, reservedVersion: 2);
        expect(result.transitionGeneration, 11);
      } else if (entry == 'enable') {
        final result = await rig.gate.enable(owner: _owner, reservedVersion: 2);
        expect(result.transitionGeneration, 11);
      } else {
        final result = await rig.gate.alignOff(const CloudEgressRecord(
            state: EgressState.on, ownerUid: _owner,
            transitionGeneration: 2, reservedVersion: 1));
        expect(result?.all, isTrue);
      }
    }

    test('$entry uses both physical native generations, not the OFF winner',
        () async {
      await transition();
      expect((nativeWrites.single.arguments as Map)['transitionGeneration'], 11);
      final records = await rig.gate.store.readOwnerLayers(_owner);
      expect(records.records.take(2).map((r) => r.transitionGeneration),
          everyElement(11));
    });
  }

  final invalid = <String, Object?>{
    'unreadable second layer': _inspection([
      _layer('file', 'OFF', 2),
      {'layer': 'keychain', 'outcome': 'unreadable'},
    ]),
    // Real egressReport substitutes retirement operation g3 for stored egress
    // g20. It must be refused, never interpreted as a stored-generation bound.
    'retirement substitutes operation generation': _inspection([
      _layer('file', 'OFF', 3, retired: true),
      _layer('keychain', 'OFF', 3, retired: true),
    ]),
    'missing inspection': null,
    'malformed inspection': {'operation': 'inspect'},
    'no-hash empty egress evidence': _inspection([]),
    'verified report without generation': _inspection([
      {'layer': 'file', 'outcome': 'verified', 'state': 'OFF'},
      _layer('keychain', 'ON', 10),
    ]),
  };
  for (final item in invalid.entries) {
    test('${item.key}: zero allocation/dispatch, no repair, valid recovery',
        () async {
      inspection = item.value;
      final secureBefore = rig.secure.value;
      final fileBefore = rig.file.value;
      await expectLater(rig.gate.beginDisabling(owner: _owner, reservedVersion: 2),
          throwsA(isA<EgressWriteFailedException>()));
      expect(rig.secure.value, secureBefore);
      expect(rig.file.value, fileBefore);
      expect(rig.secure.writes + rig.file.writes, 0);
      expect(nativeWrites, isEmpty);
      inspection = _inspection([
        _layer('file', 'OFF', 2), _layer('keychain', 'ON', 10),
      ]);
      expect((await rig.gate.beginDisabling(owner: _owner, reservedVersion: 2))
          .transitionGeneration, 11);
    });
  }

  test('restrictive disagreement still allocates above both native records',
      () async {
    inspection = _inspection([
      _layer('file', 'OFF', 2), _layer('keychain', 'DISABLING', 10),
    ]);
    expect((await rig.gate.beginDisabling(owner: _owner, reservedVersion: 2))
        .transitionGeneration, 11);
  });

  test('native rejection preserves unrelated owner and does not lower Dart',
      () async {
    rejectWrites = true;
    const unrelated = CloudEgressRecord(state: EgressState.on, ownerUid: 'uid-y',
        transitionGeneration: 40, reservedVersion: 1);
    final decoded = jsonDecode(rig.file.value!) as Map;
    (decoded['records'] as Map)['uid-y'] = unrelated.toJson();
    rig.file.value = jsonEncode(decoded);
    await expectLater(rig.gate.enable(owner: _owner, reservedVersion: 2),
        throwsA(isA<EgressWriteFailedException>()));
    final after = jsonDecode(rig.file.value!) as Map;
    expect(after['records']['uid-y'], unrelated.toJson());
    expect(after['records'][_owner]['transition_generation'], 11);
  });

  test('hidden native ON prevents false compensation absence', () async {
    const written = CloudEgressRecord(state: EgressState.on, ownerUid: _owner,
        transitionGeneration: 10, reservedVersion: 1);
    rejectWrites = true;
    expect(await rig.gate.restrictWrittenOn(written), isFalse);
    expect(nativeWrites, isNotEmpty,
        reason: 'the hidden exact ON must be judged, not claimed absent');
  });

  for (final reason in ['wrong active UID', 'stale lifecycle', 'pending barrier']) {
    test('$reason: raw native ON evidence never replaces admission denial',
        () async {
      const on = CloudEgressRecord(state: EgressState.on, ownerUid: _owner,
          transitionGeneration: 10, reservedVersion: 1);
      rig.secure.value = _envelope(on);
      rig.file.value = _envelope(on);
      final reports = [
        for (final layer in ['file', 'keychain'])
          {..._layer(layer, 'ON', 10), 'ownerGeneration': 4, 'ownerEpoch': 5},
      ];
      inspection = _inspection(reports);
      if (reason == 'pending barrier') {
        inspection = {
          ...inspection! as Map,
          'status': 'pending',
          'operationId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'transitionGeneration': 10, 'reservedVersion': 1,
          'ownerGeneration': 4, 'ownerEpoch': 5,
          'barrier': [
            for (final layer in ['file', 'keychain'])
              {'layer': layer, 'outcome': 'verified',
                'operationId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                'transitionGeneration': 10, 'reservedVersion': 1,
                'ownerGeneration': 4, 'ownerEpoch': 5},
          ],
        };
      }
      // Native cloudEgressState returns uncertain for these eligibility cases,
      // even though inspectEgress truthfully reports stored bound-ON records.
      admission = {'status': 'uncertain'};
      final raw = await rig.gate.store.readOwnerLayers(_owner);
      expect(raw.uncertain, isFalse);
      expect(raw.records, hasLength(4));
      expect(await rig.gate.permits(owner: _owner), isFalse);
      await expectLater(rig.gate.admit(owner: _owner),
          throwsA(isA<EgressDeniedException>()));
      await rig.gate.refresh();
      expect(rig.gate.permitsNetworkSync, isFalse);
      expect(nativeWrites, isEmpty);
    });
  }

  test('supersession Boolean is not proof of unreadable native cleanup', () async {
    inspection = _inspection([
      _layer('file', 'OFF', 2),
      {'layer': 'keychain', 'outcome': 'unreadable'},
    ]);
    rig.secure.value = _envelope(const CloudEgressRecord(
        state: EgressState.on, ownerUid: _owner,
        transitionGeneration: 20, reservedVersion: 1));
    const written = CloudEgressRecord(state: EgressState.on, ownerUid: _owner,
        transitionGeneration: 10, reservedVersion: 1);
    // Existing compatibility contract: visible supersession with no exact ON
    // may return true, while no claim about the unreadable native slot follows.
    expect(await rig.gate.restrictWrittenOn(written), isTrue);
    expect(nativeWrites, isEmpty);
    expect((await rig.gate.store.readOwnerLayers(_owner)).uncertain, isTrue);
  });

  test('partial native read never dispatches restrictive compensation', () async {
    inspection = _inspection([
      _layer('file', 'OFF', 2),
      {'layer': 'keychain', 'outcome': 'unreadable'},
    ]);
    const written = CloudEgressRecord(state: EgressState.on, ownerUid: _owner,
        transitionGeneration: 10, reservedVersion: 1);
    expect(await rig.gate.restrictWrittenOn(written), isFalse);
    expect(nativeWrites, isEmpty, reason: 'unverified native authority is not repaired');
  });
}
