import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/onboarding/onboarding_consent_steps.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/registration_state_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'registration-presentation-test';
  @override
  Future<String?> readStoredKey() async => 'registration-presentation-test';
}

class _ParentService implements CaptureDeviceRegistrationService {
  final value = ValueNotifier(
      const CaptureRegistrationStatus(CaptureRegistrationPhase.notRequested));
  int calls = 0;
  @override
  ValueListenable<CaptureRegistrationStatus> get status => value;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('parent_registration_operation_forbidden');
  }
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((value) => value.data)
          .toList(),
  };
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final key in visualParityRegistrationStateKeys) {
    for (final language in ['ar', 'en']) {
      testWidgets(
          '$key $language is status-only scoped presentation without SQL or actions',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final font = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await font.load();
        });
        final parent = _ParentService();
        addTearDown(parent.value.dispose);
        final container = ProviderContainer(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          captureDeviceRegistrationServiceProvider.overrideWithValue(parent),
        ]);
        addTearDown(container.dispose);
        final settings = await container.read(userSettingsProvider.future);
        expect(settings.cloudProcessingEnabled, isFalse);
        final before = await _snapshot(db);
        final actions = visualParityRegistrationStateEvents()[key] ?? 0;
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
                theme: AppTheme.light,
                darkTheme: AppTheme.dark,
                locale: Locale(language),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: Consumer(
                    builder: (context, ref, _) => Scaffold(
                            body: TextButton(
                          onPressed: () async =>
                              openVisualParityRegistrationState(
                                  context, ref, key),
                          child: const Text('Open registration presentation'),
                        ))))));
        await tester.tap(find.text('Open registration presentation'));
        await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 80)));
        // Connecting animates indefinitely; deliberately do not settle it.
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        final status = find.byType(SmartAnalysisRegistrationStatus);
        expect(status, findsOneWidget);
        final element = tester.element(status);
        final l10n = AppL10n.of(element);
        final phase = key.endsWith('NotRequested')
            ? CaptureRegistrationPhase.notRequested
            : key.endsWith('Connecting')
                ? CaptureRegistrationPhase.connecting
                : key.endsWith('Connected')
                    ? CaptureRegistrationPhase.connected
                    : CaptureRegistrationPhase.failed;
        final scoped = ProviderScope.containerOf(element);
        expect(scoped.read(captureRegistrationStatusProvider).phase, phase);
        final label = switch (phase) {
          CaptureRegistrationPhase.connecting =>
            l10n.smartConsentStatusConnecting,
          CaptureRegistrationPhase.connected =>
            l10n.smartConsentStatusConnected,
          CaptureRegistrationPhase.failed => l10n.smartConsentStatusFailed,
          CaptureRegistrationPhase.notRequested => null,
        };
        if (label != null) expect(find.text(label), findsOneWidget);
        if (phase == CaptureRegistrationPhase.notRequested) {
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text(l10n.smartConsentRetry), findsNothing);
        }
        if (key.startsWith('readiness')) {
          expect(find.byType(OnboardingReadinessStep), findsOneWidget);
          expect(find.text(l10n.onbReadyBodyOn), findsOneWidget);
          expect(
              scoped
                  .read(userSettingsProvider)
                  .valueOrNull!
                  .cloudProcessingEnabled,
              isTrue);
          expect(find.widgetWithText(FilledButton, l10n.setupCloudCta),
              findsOneWidget);
        }
        // Retry and Continue are visible public controls only; never press them.
        expect(visualParityRegistrationStateEvents()[key] ?? 0, actions);
        expect(parent.calls, 0);
        expect(
            identical(container.read(captureDeviceRegistrationServiceProvider),
                parent),
            isTrue);
        expect(
            (await container.read(userSettingsProvider.future))
                .cloudProcessingEnabled,
            isFalse);
        expect(await _snapshot(db), before);
        expect(find.textContaining('registration_presentation_'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Open registration presentation'), findsOneWidget);
        expect(parent.calls, 0);
        expect(await _snapshot(db), before);
      });
    }
  }

  testWidgets('unknown key does not create service or read settings',
      (tester) async {
    var handled = true;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityRegistrationState(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'file-backed database rejects presentation before settings or service access',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qirsh-registration-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    Object? rejected;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityRegistrationState(
                            context, ref, 'registrationConnected');
                      } catch (error) {
                        rejected = error;
                      }
                    },
                    child: const Text('Guard'))))));
    await tester.tap(find.text('Guard'));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(rejected, isA<StateError>());
    expect(rejected.toString(), contains('requires_memory_database'));
    expect(find.byType(SmartAnalysisRegistrationStatus), findsNothing);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(tester.takeException(), isNull);
  });
}
