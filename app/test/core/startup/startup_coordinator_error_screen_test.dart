import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/main.dart';

import '../session/recording_secure_storage.dart';

// O-BX (C1): a coordinator that cannot be created or proven is an ENFORCED
// startup outcome - a database-independent error screen with Retry, shown before
// any persistent replica opens - never a telemetry flag with a fail-open session.

void main() {
  const name = 'qirsh.database_access_broker.O.v1';
  late Directory support;
  late RecordingSecureStorage storage;
  ReceivePort? foreign;

  setUp(() {
    DatabaseAccessBroker.debugResetForTest();
    support = Directory.systemTemp.createTempSync('coordinator_error_');
    storage = RecordingSecureStorage().install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
  });

  tearDown(() {
    IsolateNameServer.removePortNameMapping(name);
    foreign?.close();
    foreign = null;
    DatabaseAccessBroker.debugResetForTest();
    support.deleteSync(recursive: true);
  });

  testWidgets(
      'a colliding coordinator shows the database-independent error screen with '
      'Retry; retry stays denied and opens nothing', (tester) async {
    foreign = ReceivePort();
    expect(IsolateNameServer.registerPortWithName(foreign!.sendPort, name),
        isTrue);
    final events = <String>[];
    final runner = BootstrapRunner(debugStorageEvent: events.add);
    await tester.pumpWidget(StartupApp(runner: runner));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('startup-coordinator-unavailable')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('startup-coordinator-retry')),
        findsOneWidget);
    expect(find.byType(MoneyApp), findsNothing,
        reason: 'no local-read or any other fallback');
    expect(runner.lastStep, isNull);
    expect(events, isEmpty);
    expect(storage.attempts, isEmpty);
    expect(support.listSync(), isEmpty);

    await tester.tap(find.byKey(const ValueKey('startup-coordinator-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('startup-coordinator-unavailable')),
        findsOneWidget,
        reason: 'the failed retry is still the error screen');
    expect(find.byType(MoneyApp), findsNothing);
    expect(events, isEmpty);
    expect(storage.attempts, isEmpty);
    expect(support.listSync(), isEmpty);
    expect(DatabaseAccessBroker.hasRetained, isFalse);
    expect(IsolateNameServer.lookupPortByName(name), foreign!.sendPort);
  });
}
