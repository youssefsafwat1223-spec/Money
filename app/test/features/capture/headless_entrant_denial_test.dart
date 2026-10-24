import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/features/capture/services/captured_message_processor.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:path/path.dart' as p;

import '../../core/session/recording_secure_storage.dart';

// O-H1 — headless entrants default-deny. The plugin background callback and
// the ownerless CapturedMessageProcessor paths supply no genuine host-issued
// job, so they must refuse BEFORE recording, key/lease access, opening,
// notification or acknowledgement. Every spy records ATTEMPTS.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late RecordingSecureStorage storage;
  late List<String> storageAccess;
  late List<String> platformCalls;

  setUp(() {
    support = Directory.systemTemp.createTempSync('headless_denial_');
    platformCalls = [];
    storageAccess = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async {
      platformCalls.add(call.method);
      return support.path;
    });
    storage = RecordingSecureStorage().install();
    storage.gate = (op, key) async => storageAccess.add('$op:$key');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    support.deleteSync(recursive: true);
  });

  void expectNoSideEffects() {
    expect(platformCalls, isEmpty, reason: 'no path/location resolution');
    expect(storageAccess, isEmpty, reason: 'no key, lease or owner access');
    expect(storage.attempts, isEmpty);
    expect(
        File(p.join(support.path, 'pending_notification_actions.json'))
            .existsSync(),
        isFalse,
        reason: 'nothing recorded for replay');
    expect(support.listSync(), isEmpty, reason: 'nothing created');
  }

  group('notification background action', () {
    test('without a host-issued job defers before record, open, ack',
        () async {
      for (final confirm in [true, false]) {
        final ran = await LocalNotificationService.debugRunBackgroundEntry(
            'tx-1',
            confirm: confirm);
        expect(ran, isFalse);
      }
      expectNoSideEffects();
    });

    test('a discovered or hand-built client is not a host-issued job',
        () async {
      final ran = await LocalNotificationService.debugRunBackgroundEntry('tx-1',
          confirm: true,
          job: DatabaseBrokerClient(ReceivePort().sendPort));
      expect(ran, isFalse);
      expectNoSideEffects();
    });
  });

  group('ownerless CapturedMessageProcessor', () {
    test('process() without a job is denied before any side effect',
        () async {
      await expectLater(
          CapturedMessageProcessor.process(rawMessage: 'purchase 10 SAR'),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expectNoSideEffects();
    });

    test('processCapturedMessage with an unissued client is denied too',
        () async {
      await expectLater(
          CapturedMessageProcessor.process(
              rawMessage: 'purchase 10 SAR',
              job: DatabaseBrokerClient(
                  ReceivePort().sendPort)),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expectNoSideEffects();
    });

    test('foreground host capture with its own database is not denied',
        () async {
      final db = await AppDatabase.open(executor: NativeDatabase.memory());
      try {
        Object? denied;
        try {
          await CapturedMessageProcessor.process(
              rawMessage: 'not a bank message',
              database: db,
              showNotifications: false);
        } on DatabaseAccessUnavailable catch (e) {
          denied = e;
        } catch (_) {
          // Any other outcome is the existing ingestion behavior.
        }
        expect(denied, isNull);
      } finally {
        await db.close();
      }
    });
  });
}
