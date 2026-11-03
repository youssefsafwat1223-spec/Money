import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Pinned plugin public transport boundary, no production dependency added.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/brand_continue_failure_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'brand-negative-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'brand-negative-owned-memory';
}

class _Open extends ConsumerWidget {
  const _Open();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
          body: TextButton(
        onPressed: () => openVisualParityBrandContinueFailure(context, ref),
        child: const Text('open-brand-failure'),
      ));
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return jsonEncode({
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid',
              )
              .get())
          .map((r) => r.data)
          .toList(),
  });
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'actual Brand storage rejection fixture restores transport $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final original = FlutterSecureStoragePlatform.instance;
        FlutterSecureStorage.setMockInitialValues({'qa_unrelated': 'retained'});
        final parentStorage = FlutterSecureStoragePlatform.instance;
        await AppSession.instance.load();
        final sessionBefore = AppSession.instance.value;
        expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        addTearDown(() => FlutterSecureStoragePlatform.instance = original);
        final before = await _snapshot(db);
        final admitted =
            visualParityBrandContinueFailureEvents()['admitted'] ?? 0;
        await tester.pumpWidget(ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: const _Open(),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open-brand-failure'));
        for (var i = 0;
            i < 8 && find.byType(OnboardingBrandScreen).evaluate().isEmpty;
            i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        final l =
            AppL10n.of(tester.element(find.byType(OnboardingBrandScreen)));
        final button = find.byType(FilledButton);
        await tester.tap(button);
        await tester.pump();
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(
            (visualParityBrandContinueFailureEvents()['admitted'] ?? 0) -
                admitted,
            1);
        await tester.tap(button, warnIfMissed: false);
        await tester.pump();
        expect(
            (visualParityBrandContinueFailureEvents()['admitted'] ?? 0) -
                admitted,
            1);
        releaseVisualParityBrandContinueFailure();
        await tester.pumpAndSettle();
        expect(find.text(l.setupSaveFailed), findsOneWidget);
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(
            (visualParityBrandContinueFailureEvents()['admitted'] ?? 0) -
                admitted,
            2);
        final receipt =
            await visualParityBrandContinueFailureReadback();
        expect(receipt, {
          'active': true,
          'allSqlUnchanged': true,
          'welcomeSeen': false,
          'welcomeMarker': null,
          'attempts': 2,
          'writesLanded': 0
        });
        expect(AppSession.instance.value, sessionBefore);
        expect(await _snapshot(db), before);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        Navigator.of(tester.element(find.byType(OnboardingBrandScreen))).pop();
        await tester.pumpAndSettle();
        expect(FlutterSecureStoragePlatform.instance, same(parentStorage));
        expect(await parentStorage.readAll(options: {}),
            {'qa_unrelated': 'retained'});
        expect(await _snapshot(db), before);
        expect(visualParityBrandContinueFailureEvents()['forbidden'] ?? 0, 0);
        expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      });
    }
  }
}
