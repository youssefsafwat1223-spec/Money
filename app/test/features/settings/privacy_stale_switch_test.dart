import 'dart:async';

import 'package:money_companion/l10n/app_localizations.dart';

import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/merchant_preference_writer.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';

import '../consent/consent_test_harness.dart';
import '../../core/session/f2_fixture.dart';
import '../../harness/consent_session_support.dart';

// Astra run08 P1/P2: the Privacy screen is driven by a RETAINED widget whose
// build-time settings snapshot is stale (the stored row changed meanwhile). The
// former cloud/AI switch cases are replaced by the stale-view withdrawal case in
// privacy_consent_management_test.dart (withdrawal merges into the CURRENT row;
// there is no AI-only or cloud-only daily switch any more). The merchant
// preference remains a separate local operation, tested here.

// Cloud sync and Smart Analysis are managed (status + deliberate actions), so
// the merchant preference is the only switch left on the screen.
const _merchantSwitch = 0;

// Sanitized diagnostic events: IDs only, never identity or database contents.
Future<T> _phase<T>(String id, Future<T> Function() action) async {
  // ignore: avoid_print
  print('merchant-test:$id:start');
  final result = await action().timeout(const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('merchant-test:$id:timeout'));
  // ignore: avoid_print
  print('merchant-test:$id:done');
  return result;
}

class _ObservedMerchantWriter implements MerchantPreferenceWriter {
  _ObservedMerchantWriter(this.delegate, {this.onFailure});
  final MerchantPreferenceWriter delegate;
  final void Function()? onFailure;
  Object? failure;
  final settled = Completer<void>();
  int calls = 0;

  @override
  Future<void> saveMerchantPersonalization(
      AdmissionAuthority authority, AppDatabase? database, bool enabled) async {
    calls++;
    try {
      await delegate.saveMerchantPersonalization(authority, database, enabled);
    } catch (error) {
      failure = error;
      onFailure?.call();
      rethrow;
    } finally {
      // ignore: avoid_print
      print('merchant-test:delegate-finished');
      settled.complete();
    }
  }
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    DiagnosticsConsentGate.resetForTest();
  });

  tearDown(DiagnosticsConsentGate.resetForTest);

  Future<void> pumpScreen(WidgetTester tester,
      {F2Fixture? fixture, MerchantPreferenceWriter? merchantWriter}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        merchantOffersEnabledProvider.overrideWithValue(true),
        if (fixture != null) ...[
          appDatabaseProvider.overrideWithValue(fixture.host.current!.database),
          merchantPreferenceWriterProvider.overrideWithValue(merchantWriter ??
              DriftUserSettingsRepository(fixture.host.current!.database)),
        ],
      ],
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapSwitch(WidgetTester tester, int index) async {
    final target = find.byType(SwitchListTile).at(index);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'merchant handler uses the local writer without consent or '
      'registration calls', (tester) async {
    final f = (await tester.runAsync(() async {
      final fixture = await _phase('fixture-create', F2Fixture.create);
      await _phase('fresh-sign-in', () => freshSignIn(fixture, 'uid-x'));
      await _phase('complete-onboarding', () => fixture.signIn('uid-x'));
      return fixture;
    }))!;
    addTearDown(
        () => tester.runAsync(() => _phase('fixture-dispose', f.dispose)));
    final db = f.host.current!.database;
    final writer = DriftUserSettingsRepository(db);
    final cap = f.session.captureConsentCapability()!;
    final accepted = (await tester.runAsync(() => _phase(
        'typed-consent-write',
        () => writer.saveConsentChoice(
            cap,
            const ConsentChoices(
                cloud: ConsentState.accepted, ai: ConsentState.accepted)))))!;
    repo.settings = accepted;
    // The completer must belong to real async, like the native SQL it observes.
    final observed =
        (await tester.runAsync(() async => _ObservedMerchantWriter(writer)))!;
    await _phase('pump-screen',
        () => pumpScreen(tester, fixture: f, merchantWriter: observed));
    // A concurrent decline commits while the widget retains its old snapshot.
    final denied = (await tester.runAsync(() => _phase(
        'typed-consent-write',
        () => writer.saveConsentChoice(
            cap,
            const ConsentChoices(
                cloud: ConsentState.declined, ai: ConsentState.declined)))))!;
    final rowsBefore = (await tester
        .runAsync(() => _phase('outbox-read', () => settingsOutboxRows(db))))!;
    final savesBefore = repo.saveCalls;

    final target = find.byType(SwitchListTile).at(_merchantSwitch);
    await _phase('ensure-visible', () => tester.ensureVisible(target));
    await tester.runAsync(() async {
      await _phase('tap', () => tester.tap(target));
      expect(observed.calls, 1, reason: 'the real local writer started');
      await _phase('merchant-settled', () => observed.settled.future);
    });
    expect(observed.calls, 1);
    await _phase('pump-settle', () => tester.pumpAndSettle());

    final stored = (await tester
        .runAsync(() => _phase('settings-read', writer.getSettings)))!;
    expect(stored.merchantPersonalizationEnabled, isTrue);
    expect(stored.cloudConsentState, ConsentState.declined);
    expect(stored.aiConsentState, ConsentState.declined);
    expect(stored.cloudConsentVersion, denied.cloudConsentVersion);
    expect(stored.aiConsentVersion, denied.aiConsentVersion);
    expect(stored.cloudConsentAt, denied.cloudConsentAt);
    expect(stored.aiConsentAt, denied.aiConsentAt);
    expect(
        await tester.runAsync(
            () => _phase('outbox-read', () => settingsOutboxRows(db))),
        rowsBefore);
    expect(repo.saveCalls, savesBefore, reason: 'no generic entity save');
    expect(repo.lastChoices, isNull);
    expect(service.enableCalls, 0);
    expect(service.disableCalls, 0);
    expect(service.syncCalls, 0);
  });

  for (final stale in [false, true]) {
    testWidgets(
        stale
            ? 'merchant handler suppresses storage errors after its scope becomes stale'
            : 'merchant handler reports a real SQLite storage error without unhandled callback or consent grant',
        (tester) async {
      final f = (await tester.runAsync(() async {
        final fixture = await _phase('fixture-create', F2Fixture.create);
        await _phase('fresh-sign-in', () => freshSignIn(fixture, 'uid-x'));
        await _phase('complete-onboarding', () => fixture.signIn('uid-x'));
        return fixture;
      }))!;
      addTearDown(
          () => tester.runAsync(() => _phase('fixture-dispose', f.dispose)));
      final db = f.host.current!.database;
      final writer = DriftUserSettingsRepository(db);
      Future<List<Map<String, dynamic>>> snapshot(String table) async =>
          (await db.customSelect('SELECT * FROM $table ORDER BY id;').get())
              .map((row) => Map<String, dynamic>.from(row.data))
              .toList();
      repo.settings = (await tester.runAsync(() => writer.getSettings()))!;
      final before = (await tester.runAsync(() => snapshot('user_settings')))!;
      final outbox =
          (await tester.runAsync(() => snapshot('planning_sync_outbox')))!;
      await tester.runAsync(() => db.customStatement(
          "CREATE TRIGGER merchant_test_storage_reject BEFORE UPDATE OF "
          "merchant_personalization_enabled ON user_settings BEGIN SELECT "
          "RAISE(ABORT, 'merchant_test_storage_failure'); END;"));
      final observed = (await tester.runAsync(() async =>
          _ObservedMerchantWriter(writer,
              onFailure: stale ? f.session.markSessionInvalid : null)))!;
      await pumpScreen(tester, fixture: f, merchantWriter: observed);
      final genericError =
          AppL10n.of(tester.element(find.byType(PrivacyScreen)))
              .setupSaveFailed;
      final target = find.byType(SwitchListTile).at(_merchantSwitch);
      await tester.ensureVisible(target);
      await tester.runAsync(() async {
        await _phase('tap', () => tester.tap(target));
        await _phase('merchant-settled', () => observed.settled.future);
      });
      await tester.pump();
      expect(observed.calls, 1);
      expect(observed.failure, isNotNull);
      expect(observed.failure.toString(),
          contains('merchant_test_storage_failure'));
      expect(await tester.runAsync(() => snapshot('user_settings')), before);
      expect(await tester.runAsync(() => snapshot('planning_sync_outbox')),
          outbox);
      expect(repo.saveCalls, 0);
      expect(repo.lastChoices, isNull);
      expect(service.enableCalls, 0);
      expect(service.disableCalls, 0);
      expect(service.syncCalls, 0);
      expect(service.retryCalls, 0);
      expect(tester.takeException(), isNull);
      expect(find.text(genericError), stale ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('auth loss after merchant SQL rolls the handler write back',
      (tester) async {
    final f = (await tester.runAsync(() async {
      final fixture = await _phase('fixture-create', F2Fixture.create);
      await _phase('fresh-sign-in', () => freshSignIn(fixture, 'uid-x'));
      await _phase('complete-onboarding', () => fixture.signIn('uid-x'));
      return fixture;
    }))!;
    addTearDown(
        () => tester.runAsync(() => _phase('fixture-dispose', f.dispose)));
    final db = f.host.current!.database;
    final writer =
        DriftUserSettingsRepository(db, afterMerchantUpdate: () async {
      f.session.markSessionInvalid();
    });
    final before = (await tester
        .runAsync(() => _phase('settings-read', writer.getSettings)))!;
    repo.settings = before;
    // The completer must belong to real async, like the native SQL it observes.
    final observed =
        (await tester.runAsync(() async => _ObservedMerchantWriter(writer)))!;
    await _phase('pump-screen',
        () => pumpScreen(tester, fixture: f, merchantWriter: observed));
    final target = find.byType(SwitchListTile).at(_merchantSwitch);
    await _phase('ensure-visible', () => tester.ensureVisible(target));
    await tester.runAsync(() async {
      await _phase('tap', () => tester.tap(target));
      expect(observed.calls, 1, reason: 'the real local writer started');
      await _phase('merchant-settled', () => observed.settled.future);
    });
    expect(observed.calls, 1);
    await _phase('pump-settle', () => tester.pumpAndSettle());
    final stored = (await tester
        .runAsync(() => _phase('settings-read', writer.getSettings)))!;
    expect(stored.merchantPersonalizationEnabled,
        before.merchantPersonalizationEnabled);
    expect(service.enableCalls, 0);
    expect(service.disableCalls, 0);
    expect(service.syncCalls, 0);
  });

  testWidgets('consent-only onboarding cannot change merchant preference',
      (tester) async {
    final f = (await tester.runAsync(() async {
      final fixture = await _phase('fixture-create', F2Fixture.create);
      await _phase('fresh-sign-in', () => freshSignIn(fixture, 'uid-x'));
      return fixture;
    }))!;
    addTearDown(
        () => tester.runAsync(() => _phase('fixture-dispose', f.dispose)));
    final writer = DriftUserSettingsRepository(f.host.current!.database);
    final before = (await tester
        .runAsync(() => _phase('settings-read', writer.getSettings)))!;
    repo.settings = before;
    // The completer must belong to real async, like the native SQL it observes.
    final observed =
        (await tester.runAsync(() async => _ObservedMerchantWriter(writer)))!;
    await _phase('pump-screen',
        () => pumpScreen(tester, fixture: f, merchantWriter: observed));
    await _phase('onboarding-tap', () => tapSwitch(tester, _merchantSwitch));
    expect(observed.calls, 0);
    expect(
        (await tester
                .runAsync(() => _phase('settings-read', writer.getSettings)))!
            .merchantPersonalizationEnabled,
        before.merchantPersonalizationEnabled);
    expect(service.enableCalls, 0);
    expect(service.disableCalls, 0);
    expect(service.syncCalls, 0);
  });
}
