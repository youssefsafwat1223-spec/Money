import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// N-E static pins on the native-backed enable flow and the Dart pending denial.
/// Behaviour is proven by the flow tests; these pins make the ordering and the
/// forbidden shortcuts regressions fail in source review as well.
String _body(String source, String signature) {
  final at = source.indexOf(signature);
  if (at < 0) throw StateError('$signature not found');
  final open = source.indexOf('{', at + signature.length);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  throw StateError('unbalanced braces after $signature');
}

void main() {
  late String service;
  late String gate;
  late String flow;

  setUpAll(() {
    service = File(
            'lib/features/capture/services/capture_device_registration_service.dart')
        .readAsStringSync();
    gate = File('lib/core/privacy/cloud_egress_gate.dart').readAsStringSync();
    flow = _body(service, 'Future<void> _enableCloudNative(');
  });

  test('the native flow never takes the generic ON path or the network', () {
    for (final forbidden in [
      '_gate.enable(',
      'store.write(',
      'writeRecord(',
      '_backendClient',
      '_consent.',
      'registerDevice',
      'syncBackendState',
      '_linkOnce',
      'linkToCurrentUser',
      'setCloudEgressState',
    ]) {
      expect(flow, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('phases are ordered: prerequisite, freeze, pending, begin, bind, ON, '
      'save, complete, clear', () {
    final order = [
      'committedOwnerLifetime(',
      'freezeEnable(',
      'beginPendingEnable(',
      'NativeCaptureBridge.beginCloudEgressEnable(',
      'bindPendingEnable(',
      'writeDartOn(',
      'NativeCaptureBridge.writeCloudEgressEnableOn(',
      'saveConsentChoice(',
      'NativeCaptureBridge.finishCloudEgressEnable(',
      'clearPendingEnable(',
    ];
    var last = -1;
    for (final marker in order) {
      final at = flow.indexOf(marker, last + 1);
      expect(at, greaterThan(last), reason: marker);
      last = at;
    }
  });

  test('every native phase is judged by its structured confirmation', () {
    for (final confirm in [
      'confirmsBarrierEstablished',
      'confirmsOnWritten',
      'confirmsCompleted',
      'confirmsRestricted',
      'confirmsAbandoned',
    ]) {
      expect(service, contains(confirm));
    }
  });

  test('the typed save is the only local-drain work of the flow', () {
    expect('saveConsentChoice('.allMatches(flow).length, 1);
    expect('runConsentLocalOperation('.allMatches(flow).length, 1);
    final at = flow.indexOf('runConsentLocalOperation(');
    final after = flow.substring(at, at + 400);
    expect(after, contains('saveConsentChoice('));
    expect(after, isNot(contains('NativeCaptureBridge')));
  });

  test('the Dart-only ON writer does not touch the native layer', () {
    final writeOn = _body(gate, 'Future<PendingWriteResult> writeDartOn(');
    expect(writeOn, isNot(contains('native')));
    final restrict =
        _body(gate, 'Future<PendingWriteResult> restrictDartLayers(');
    expect(restrict, isNot(contains('native')));
  });

  test('every admission path consults the pending denial', () {
    for (final sig in [
      'Future<bool> permits({String? owner}) async',
      'Future<String?> _decide(\n      String owner, EgressGrant? grant, AdmissionRequest? request) async',
      'Future<void> refresh() async',
    ]) {
      expect(_body(gate, sig), contains('pending'), reason: sig);
    }
    expect(_body(gate, 'bool get permitsNetworkSync'), contains('Pending'));
  });

  test('the pending layers use their own keys', () {
    expect(gate, contains("kPendingSecureKey = 'qirsh.cloud_egress_pending.v1'"));
    expect(gate, contains("kPendingFileName = 'cloud_egress_pending.v1'"));
  });

  test('the sheet reports an incomplete enable; the screen has no enable', () {
    final privacy =
        File('lib/features/settings/privacy_screen.dart').readAsStringSync();
    final sheet = File('lib/features/consent/smart_analysis_consent_sheet.dart')
        .readAsStringSync();
    expect(privacy, isNot(contains('enableCloud(')));
    expect(privacy, isNot(contains('CloudEnableIncompleteException')));
    expect(sheet, contains('CloudEnableIncompleteException'));
    expect(sheet, contains('cloudEnableIncomplete'));
    expect(sheet, contains('CloudEnableWithdrawFirstException'));
    expect(sheet, contains('cloudEnableWithdrawFirst'));
  });
}
