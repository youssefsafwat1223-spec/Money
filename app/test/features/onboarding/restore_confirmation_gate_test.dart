import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// MALI-014 §Blocker-5 — the production restore UI drives the RestoreController and
// ENFORCES an explicit confirmation gate: preparation does not mutate, the mutation
// service is never called before confirmation, and cancellation changes nothing.

class _RecordingBackupService implements BackupService {
  int prepareCalls = 0;
  int commitCalls = 0;

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async {
    prepareCalls++;
    return RestorePlan(
      operationId: 'op',
      envelopeVersion: 3,
      snapshotSchemaVersion: 3,
      sourceFingerprint: 'fp',
      tables: const {},
      warnings: const [],
    );
  }

  @override
  Future<RestoreResult> commitRestore({required RestorePlan plan}) async {
    commitCalls++;
    return const RestoreResult(RestoreOutcome.success, operationId: 'op');
  }

  @override
  Future<void> restoreFromBackup({required String passphrase}) async {}
  @override
  Future<BackupStatus> status() async => const BackupStatus(enabled: false);
  @override
  Future<bool> hasRemoteBackup() async => false;
  @override
  Future<String> enable({required String passphrase}) async => 'X';
  @override
  Future<void> backupNow() async {}
  @override
  Future<void> disable() async {}
  @override
  Future<void> deleteRemoteBackups() async {}
}

Widget _app(_RecordingBackupService service) {
  final router = GoRouter(
    routes: [
      GoRoute(
          path: '/',
          builder: (_, __) =>
              const RestorePromptScreen(onboardingFlow: false)),
      GoRoute(
          path: '/data-transfer',
          builder: (_, __) => const Scaffold(body: Text('DATA-TRANSFER'))),
    ],
  );
  return ProviderScope(
    overrides: [backupServiceProvider.overrideWithValue(service)],
    child: MaterialApp.router(
      theme: AppTheme.light,
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    ),
  );
}

// The screen has infinite intro animations, so use bounded pumps (never
// pumpAndSettle) to let async work + the dialog settle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _startRestore(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, 'passphrase123');
  await tester.pump();
  await tester.ensureVisible(find.byKey(const Key('restore_cta')));
  await tester.tap(find.byKey(const Key('restore_cta')));
  await _settle(tester);
}

void main() {
  testWidgets('preparation runs but the mutation is NOT called until the user '
      'confirms — the confirmation dialog appears first', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _RecordingBackupService();

    await tester.pumpWidget(_app(service));
    await _startRestore(tester);

    expect(service.prepareCalls, 1);
    expect(service.commitCalls, 0, reason: 'no mutation before confirmation');
    expect(find.text('تأكيد الاستعادة'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation changes nothing (mutation never runs)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _RecordingBackupService();

    await tester.pumpWidget(_app(service));
    await _startRestore(tester);
    await tester.tap(find.text('إلغاء'));
    await _settle(tester);

    expect(service.commitCalls, 0, reason: 'cancellation runs no mutation');
    expect(find.text('DATA-TRANSFER'), findsNothing);
  });

  testWidgets('confirming runs the mutation and navigates on completion',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _RecordingBackupService();

    await tester.pumpWidget(_app(service));
    await _startRestore(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('استعادة'),
      ),
    );
    await _settle(tester);

    expect(service.commitCalls, 1, reason: 'mutation runs only after confirm');
    expect(find.text('DATA-TRANSFER'), findsOneWidget);
  });
}
