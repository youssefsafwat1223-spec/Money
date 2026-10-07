import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CAP-7 (`capture_notify_v2`) + A6 source contracts. Swift cannot run under
/// `flutter test`; the behavioural proofs are ios/RunnerTests/RunnerTests.swift
/// (`testPeekLegacyCaptureItems...`, `testNotifyV2OwnerRule...`, Mac) and the
/// device gates DG3 (T-D9, T-D10, X9). These pins fail in Linux CI if the
/// properties that make them true regress.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final intent = read('ios/BankMessageShortcuts/BankMessageShortcuts.swift');
  final delegate = read('ios/Runner/AppDelegate.swift');
  final store = read('ios/Runner/SharedCaptureStore.swift');
  final storeCopy = read('ios/ShareBankMessage/SharedCaptureStore.swift');
  final shell = read('lib/features/app/app_shell.dart');
  final xctest = read('ios/RunnerTests/RunnerTests.swift');

  /// The text from the `{` after [signature] to its matching `}`.
  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('flags', () {
    test('both flags are seeded OFF in the catalog and the defaults', () {
      final json = read('assets/catalog/feature_flags.json');
      for (final key in ['capture_notify_v2', 'capture_notify_shared_ids']) {
        final m = RegExp(
                '"key": "$key",[^}]*"value": "(\\w+)"[^}]*"is_active": (true|false)')
            .firstMatch(json);
        expect(m, isNotNull, reason: key);
        expect(m!.group(1), 'false', reason: key);
        expect(m.group(2), 'false', reason: key);
      }
      final defaults = read('lib/data/catalog/feature_flag_service.dart');
      expect(defaults, contains("'capture_notify_v2': false"));
      expect(defaults, contains("'capture_notify_shared_ids': false"));
    });

    test('shared identifiers are not implemented before T-N4: nothing reads it',
        () {
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.path.endsWith('feature_flag_service.dart')) continue;
        expect(f.readAsStringSync(), isNot(contains('capture_notify_shared_ids')),
            reason: f.path);
      }
      expect(intent, isNot(contains('capture_notify_shared_ids')));
    });

    test('the shell reads the flag; OFF keeps the shipped per-item notification',
        () {
      expect(shell, contains("featureFlags.getBool('capture_notify_v2')"));
      expect(shell, contains('if (!notifyV2 &&\n            CaptureNotificationAuthority.shouldShowLocalReview('));
      expect(shell, contains('if (notifyV2) await _alertImportedV2('));
    });
  });

  group('App Intent owner rule (T-D9)', () {
    test('the mirror is read from the shared store and defaults to false', () {
      expect(store, contains('var captureNotifyV2: Bool = false'));
      expect(store,
          contains('captureNotifyV2: defaults?.bool(forKey: notifyV2Key) ?? false'));
      expect(storeCopy, store, reason: 'both copies are byte-identical');
    });

    test('the response carries push_attempted and the banner follows it', () {
      expect(intent, contains('json["push_attempted"] as? Bool'));
      final perform = body(intent, 'func perform()');
      expect(perform, contains('if config.captureNotifyV2 {'));
      expect(perform, contains('response.pushAttempted ?? response.pushSent'));
      // OFF: the shipped rule is still there, unchanged.
      expect(perform, contains('} else if !response.pushSent {'));
      expect(perform, contains('identifierPrefix: "capture_backend"'));
    });

    test('every local banner site goes generic under the flag', () {
      final perform = body(intent, 'func perform()');
      expect(
          RegExp(r'await scheduleGenericCaptureNotification\(payloadID: payloadID\)')
              .allMatches(perform)
              .length,
          4,
          reason: 'localOnly, push_attempted=false, backend unreachable, cloud off');
      expect(RegExp('if config.captureNotifyV2').allMatches(perform).length, 4);
    });

    test('the waiting item shows no banner (not this owner\'s to alert)', () {
      final perform = body(intent, 'func perform()');
      final waiting = perform.substring(perform.indexOf('case .waiting:'),
          perform.indexOf('let attempt = await processBackend'));
      expect(waiting, isNot(contains('schedule')));
    });
  });

  group('generic text on every channel (X9)', () {
    test('the generic banner touches no amount, merchant, card, sender or text',
        () {
      final fn = body(intent, 'private func scheduleGenericCaptureNotification');
      for (final forbidden in [
        'smsText',
        'senderName',
        'senderID',
        'PreviewParser',
        'merchant',
        'amount',
        'last4',
        'response.notification',
      ]) {
        expect(fn, isNot(contains(forbidden)), reason: forbidden);
      }
      expect(fn, contains('title: ""'));
      expect(fn, contains('identifierPrefix: "capture_generic"'));
      expect(intent, contains('"New transaction captured"'));
    });

    test('Dart: the OS edge forces generic text for capture alerts under the flag',
        () {
      final svc = read('lib/features/capture/services/local_notification_service.dart');
      final show = body(svc, 'Future<void> _show({');
      expect(show, contains('lockScreenContentFor('));
      expect(show, contains('captureNotifyV2: captureNotifyV2()'));
      final bg = read('lib/features/capture/services/captured_message_processor.dart');
      expect(bg, contains("featureFlags.getBool('capture_notify_v2')"));
    });

    test('the server wording constant is not changed by CAP-7', () {
      expect(read('../supabase/functions/_shared/capture_push.ts'),
          contains("body: 'New transaction captured'"));
    });
  });

  group('channel parity', () {
    test('AppDelegate implements every CAP-7 / A6 method Dart calls', () {
      final bridge = read('lib/features/capture/services/native_capture_bridge.dart');
      for (final m in [
        'peekLegacyCaptureItems',
        'setCaptureNotifyV2',
        'withdrawDeliveredCaptureAlert',
      ]) {
        expect(bridge, contains("'$m'"), reason: m);
        expect(delegate, contains('case "$m":'), reason: m);
      }
    });

    test('the withdraw identifiers are the App Intent\'s own', () {
      final fn = delegate.substring(delegate.indexOf('case "withdrawDeliveredCaptureAlert"'));
      for (final prefix in ['capture_generic_', 'capture_fallback_', 'capture_backend_']) {
        expect(fn.substring(0, 900), contains('"$prefix"'));
        expect(intent, contains('"${prefix.substring(0, prefix.length - 1)}"'));
      }
    });
  });

  group('A6: peekLegacyCaptureItems', () {
    test('runs under the flock, is read-only and lists only unbound legacy_v2',
        () {
      final fn = body(store, 'static func peekLegacyCaptureItems()');
      expect(fn.trimLeft().substring(1).trimLeft(), startsWith('try withQueueLock'));
      expect(fn, contains('item.origin == originLegacyV2'));
      expect(fn, contains('item.ownerState == ownerStateUnbound'));
      expect(fn, contains('loadQueue()'));
      expect(fn, isNot(contains('saveQueue')));
      expect(fn, isNot(contains('loadQueuePruned')),
          reason: 'listing must not prune (mutate) the queue');
      expect(storeCopy, store);
    });

    test('nothing logs the listed content', () {
      final fn = body(store, 'static func peekLegacyCaptureItems()');
      for (final sink in ['NSLog', 'print(', 'debugPrint', 'os_log']) {
        expect(fn, isNot(contains(sink)));
      }
      final handler = delegate.substring(delegate.indexOf('case "peekLegacyCaptureItems"'),
          delegate.indexOf('case "setCaptureNotifyV2"'));
      for (final sink in ['NSLog', 'print(', 'debugPrint', 'os_log']) {
        expect(handler, isNot(contains(sink)));
      }
    });

    test('the resolver\'s legacyItems source is wired to the native listing', () {
      final providers = read('lib/core/di/app_providers.dart');
      final at = providers.indexOf('final legacyCaptureResolverProvider');
      final block = providers.substring(at, providers.indexOf('});', at));
      expect(block, contains('legacyItems:'));
      expect(block, contains('NativeCaptureBridge.peekLegacyCaptureItems()'));
    });

    test('an XCTest covers the listing', () {
      expect(xctest, contains('testPeekLegacyCaptureItemsListsOnlyUnboundLegacyAndChangesNothing'));
    });
  });
}
