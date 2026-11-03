import 'dart:convert';
// Use pinned plugin public test boundary; no production dependency added.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../tool/visual_parity/app_lock_failure_surfaces.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'lock-review-memory';
  @override
  Future<String?> readStoredKey() async => 'lock-review-memory';
}

class _Open extends ConsumerWidget {
  const _Open();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(body: TextButton(onPressed: () => openVisualParityAppLockFailure(context, ref), child: const Text('open-lock-fixture')));
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
      {
        testWidgets(
            'lock failed OFF keeps stored ON and permits retry $language dark=$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final previousStorage = FlutterSecureStoragePlatform.instance;
          FlutterSecureStorage.setMockInitialValues({'app_lock_enabled': '0', 'qa_unrelated_key': 'retained'});
          final parentStorage = FlutterSecureStoragePlatform.instance;
          final admittedBefore = visualParityAppLockFailureEvents()['admitted'] ?? 0;
          addTearDown(
              () => FlutterSecureStoragePlatform.instance = previousStorage);
          final db = await AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _MemoryKeys(),
          );
          final before = await _snapshot(db);
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
          await tester.tap(find.text('open-lock-fixture'));
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
          final tile = find.widgetWithText(SwitchListTile, l10n.setAppLock);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          await tester.tap(tile);
          await tester.pump();
          expect((visualParityAppLockFailureEvents()['admitted'] ?? 0) - admittedBefore, 1);
          await tester.tap(tile);
          await tester.pump();
          expect((visualParityAppLockFailureEvents()['admitted'] ?? 0) - admittedBefore, 1,
              reason: 'held storage write must not admit another toggle');
          releaseVisualParityAppLockFailure();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: 'storage failure is a recoverable UI error');
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          expect(find.text(l10n.setupSaveFailed), findsOneWidget);
          expect(find.textContaining('private_lock_diagnostic'), findsNothing);
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect((visualParityAppLockFailureEvents()['admitted'] ?? 0) - admittedBefore, 2,
              reason: 'failure clears busy and allows deliberate retry');
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          expect(await _snapshot(db), before);
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
          await tester.pumpAndSettle();
          expect(identical(FlutterSecureStoragePlatform.instance, parentStorage), isTrue);
          expect(await parentStorage.readAll(options: {}), {'app_lock_enabled': '0', 'qa_unrelated_key': 'retained'});
          expect(visualParityAppLockFailureEvents()['forbidden'] ?? 0, 0);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
