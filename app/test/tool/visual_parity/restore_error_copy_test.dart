import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/restore_negative_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'restore-negative-memory';
  @override
  Future<String?> readStoredKey() async => 'restore-negative-memory';
}

Future<Map<String, List<Map<String, Object?>>>> _sql(AppDatabase db) async {
  final names = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final n in names)
      n.read<String>('name'): [
        for (final row in await db
            .customSelect('SELECT * FROM "${n.read<String>('name')}"')
            .get())
          row.data
      ]
  };
}

void main() {
  for (final key in ['restorePreparationFailure']) {
    for (final lang in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('actual restore preparation error full copy $lang dark$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final db = await AppDatabase.open(
              executor: NativeDatabase.memory(), keyStore: _Keys());
          final before = await _sql(db);
          final service = FailureOnlyRestorePreparation(key);
          var http = 0;
          var pendingExceeded = true, pendingVisible = false;
          await HttpOverrides.runZoned(() async {
            await tester.pumpWidget(ProviderScope(
                overrides: [
                  appDatabaseProvider.overrideWithValue(db),
                  backupServiceProvider.overrideWithValue(service)
                ],
                child: MaterialApp(
                    theme: dark ? AppTheme.dark : AppTheme.light,
                    locale: Locale(lang),
                    supportedLocales: AppL10n.supportedLocales,
                    localizationsDelegates: AppL10n.localizationsDelegates,
                    home: const RestorePromptScreen(onboardingFlow: false))));
            await tester.pumpAndSettle();
            final l =
                AppL10n.of(tester.element(find.byType(RestorePromptScreen)));
            final field = find.byType(TextField).first;
            await tester.enterText(field, 'qa-restore-secret');
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
            final restore = find.byKey(const Key('restore_cta'));
            await tester.ensureVisible(restore);
            await tester.tap(restore);
            await tester.pump();
            expect(service.calls, 1);
            expect(tester.widget<FilledButton>(restore).onPressed, isNull);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            await tester.tap(restore, warnIfMissed: false);
            await tester.pump();
            expect(service.calls, 1);
            service.release();
            await tester.pumpAndSettle();
            expect(tester.widget<FilledButton>(restore).onPressed, isNotNull);
            expect(
                find.text(key == 'restoreWrongPassphrase'
                    ? l.bkeWrongPassphrase
                    : l.bkePrepareFailed),
                findsOneWidget);
            final fullCopy = find.byWidgetPredicate((widget) => widget is RichText && widget.text.toPlainText() == l.bkePrepareFailed);
            expect(fullCopy, findsOneWidget);
            await tester.ensureVisible(fullCopy);
            await tester.pumpAndSettle();
            final paragraph = tester.renderObject<RenderParagraph>(fullCopy);
            final exceeded = paragraph.didExceedMaxLines;
            final paragraphRect = tester.getRect(fullCopy);
            debugPrint('RESTORE_ERROR_COPY lang=$lang dark=$dark exceeded=$exceeded maxLines=${paragraph.maxLines} size=${paragraph.size} rect=$paragraphRect');
            final visible = paragraphRect.top >= 0 && paragraphRect.bottom <= 667 && paragraphRect.left >= 0 && paragraphRect.right <= 375;
            expect(find.textContaining('private_synthetic'), findsNothing);
            expect(tester.widget<TextField>(field).controller!.text,
                'qa-restore-secret');
            await tester.ensureVisible(restore);
            await tester.tap(restore);
            await tester.pumpAndSettle();
            expect(service.calls, 2);
            expect(tester.takeException(), isNull);
            expect(
                visualParityRestoreNegativeEvents()['${key}Forbidden'] ?? 0, 0);
            expect(http, 0);
            // Preserve cleanup and SQL verification even on the baseline failure.
            pendingExceeded = exceeded;
            pendingVisible = visible;
          }, createHttpClient: (context) {
            http++;
            throw StateError('restore_negative_must_not_network');
          });
          expect(await _sql(db), before);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          expect(pendingVisible, isTrue);
          expect(pendingExceeded, isFalse, reason: 'the complete localized preparation failure must be readable without ellipsis');
        });
      }
    }
  }
}
