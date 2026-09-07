import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every platform capture entry point must have a DURABLE path.
///
/// Capture has one live topology: a native durable queue that both platforms
/// write into, drained by `AppShell._consumeSharedInput` under a per-item
/// lease. A second entry point — a background Dart isolate, a native path that
/// parses and commits on its own, a `vm:entry-point` nobody dispatches — is the
/// failure this pins. `sms_background_handler.dart` was exactly that: a
/// `@pragma('vm:entry-point')` no-op with no dispatcher on either platform,
/// which two separate audits had to stop and explain before ruling it out.
///
/// "Durable" here means: a captured message ends as a transaction (confirmed or
/// pending review), a persisted suspected duplicate, a Smart Inbox row the user
/// can act on, or it stays in the native queue for the next drain. Never a
/// silent drop.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final nativeSources = [
    ...Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt')),
    ...Directory('ios')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.swift') && !f.path.contains('/ephemeral/')),
  ];

  group('capture entry points', () {
    test('the ONLY capture channel is money_companion/native_capture', () {
      final bridge =
          read('lib/features/capture/services/native_capture_bridge.dart');
      expect(bridge, contains("MethodChannel('money_companion/native_capture')"));

      final dartChannels = RegExp(r"MethodChannel\('([^']+)'\)")
          .allMatches(read('lib/features/capture/services/native_capture_bridge.dart'))
          .map((m) => m.group(1))
          .toSet();
      expect(dartChannels, {'money_companion/native_capture'},
          reason: 'a second capture channel is a second entry point');
    });

    test('no native code dispatches a background Dart entry point', () {
      // A background isolate would be a capture authority this guard, the
      // drain, and the Proof/consent gates know nothing about.
      const forbidden = [
        'FlutterCallbackInformation',
        'DartCallback',
        'FlutterEngineGroup',
      ];
      for (final file in nativeSources) {
        final body = file.readAsStringSync();
        for (final token in forbidden) {
          expect(body.contains(token), isFalse,
              reason: '${file.path} dispatches Dart out of band ($token) — '
                  'capture would bypass the drain');
        }
      }
    });

    test('every Dart vm:entry-point is registered by something', () {
      // An unregistered entry point is dead weight that reads as a live path.
      // The notification background tap handler is registered with the plugin;
      // anything else must justify itself here deliberately.
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final body = file.readAsStringSync();
        if (!body.contains("@pragma('vm:entry-point')")) continue;
        for (final m in RegExp(
                r"@pragma\('vm:entry-point'\)\s*\n\s*(?:static\s+)?(?:void|Future<[^>]*>)\s+(\w+)")
            .allMatches(body)) {
          final name = m.group(1)!;
          final referenced = Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .any((f) =>
                  f.readAsStringSync().split(RegExp(r'@pragma')).length > 1
                      ? f.readAsStringSync().contains('$name,') ||
                          f.readAsStringSync().contains('$name)')
                      : f.readAsStringSync().contains(name));
          if (!referenced) offenders.add('${file.path}:$name');
        }
      }
      expect(offenders, isEmpty,
          reason: 'unreachable background entry point(s): $offenders');
    });

    test('Android SMS capture enqueues durably and never calls Dart', () {
      final receiver = read(
          'android/app/src/main/kotlin/com/example/money_companion/SmsCaptureReceiver.kt');
      expect(receiver, contains('DurableCaptureQueue.get(context).enqueue('),
          reason: 'a received SMS must land in the durable queue');
      expect(receiver, contains('UUID.randomUUID().toString()'),
          reason: 'every payload needs a stable id or it can never be acked');
      expect(receiver.contains('MethodChannel'), isFalse,
          reason: 'the receiver must not reach into Dart directly');
      expect(receiver, contains('isAutoCaptureEnabled'),
          reason: 'permission alone is not consent to read');
    });

    test('Android share capture enqueues into the same durable queue', () {
      final main = read(
          'android/app/src/main/kotlin/com/example/money_companion/MainActivity.kt');
      expect(main, contains('DurableCaptureQueue.get(this).enqueue('));
      expect(main, contains('DurableCaptureQueue.get(this).peekJson()'),
          reason: 'the drain must PEEK, not destructively read');
      expect(main, contains('DurableCaptureQueue.get(this).acknowledge('),
          reason: 'per-item ack is the lease boundary');
    });

    test('iOS capture mints a stable payload id', () {
      final store = read('ios/Runner/SharedCaptureStore.swift');
      expect(store, contains('func makePayloadID('),
          reason: 'without an id the message can never be acknowledged');
    });
  });

  group('the drain is the single durable owner', () {
    test('every disposition is handled by the drain notification switch', () {
      final shell = read('lib/features/app/app_shell.dart');
      final switchBody = shell.substring(
          shell.indexOf('Future<void> _showCapturedMessageNotification'));
      for (final d in [
        'CapturedMessageDisposition.ignored',
        'CapturedMessageDisposition.notifyOnly',
        'CapturedMessageDisposition.requestConfirmation',
        'CapturedMessageDisposition.suspiciousDuplicate',
        'CapturedMessageDisposition.unprocessable',
      ]) {
        expect(switchBody, contains(d),
            reason: '$d has no notification branch on the live path');
      }
    });

    test('an unprocessable capture is persisted BEFORE it is acknowledged', () {
      final handoff = read(
          'lib/features/capture/services/shared_capture_handoff_service.dart');
      final unprocessableAt =
          handoff.indexOf('case CapturedMessageDisposition.unprocessable:');
      final persistAt = handoff.indexOf('persistUnprocessableCapture');
      final ackAt = handoff.indexOf('await _acknowledge(payloadId)');
      expect(unprocessableAt, isNot(-1));
      expect(persistAt, greaterThan(unprocessableAt),
          reason: 'the Smart Inbox row must be written in this branch');
      expect(ackAt, greaterThan(persistAt),
          reason: 'acknowledging before persisting is a silent drop');
      expect(handoff, contains('SharedCaptureHandoffOutcome.retained'),
          reason: 'a message that could not be made durable must be retried');
    });

    test('a committed outcome without a transaction is retained, not acked',
        () {
      final handoff = read(
          'lib/features/capture/services/shared_capture_handoff_service.dart');
      expect(handoff, contains('if (transactionId == null) {'),
          reason: 'notifyOnly/requestConfirmation/duplicate promise a row');
    });

    test('the drain re-ingests on device only', () {
      final shell = read('lib/features/app/app_shell.dart');
      expect(shell, contains('onDeviceOnly: true'),
          reason: 'a later drain must never re-send an SMS to AI/enrichment');
    });
  });

  group('manual recovery always exists', () {
    test('the capture sheet offers paste AND manual entry', () {
      final sheet = read('lib/features/capture/capture_entry_sheet.dart');
      expect(sheet, contains('ManualPasteScreen.showSheet'));
      expect(sheet, contains('ManualTransactionSheet.show'));
    });

    test('capture copy does not promise automatic AI classification', () {
      // AI consent is `unset` by default, so a build that promises automatic AI
      // handling is lying to most installs.
      final sheet = read('lib/features/capture/capture_entry_sheet.dart');
      expect(sheet.contains('بتصنيفها وإضافتها تلقائياً'), isFalse);
    });

    test('no raw AI reason token reaches the user', () {
      final paste = read('lib/features/capture/manual_paste_screen.dart');
      expect(paste.contains(r'فشل الذكاء الاصطناعي: $reason'), isFalse,
          reason: 'consent_off is an internal identifier, not user copy');
      expect(paste, contains("'consent_off'"),
          reason: 'the skip reasons must still be classified, just not printed');
    });
  });
}
