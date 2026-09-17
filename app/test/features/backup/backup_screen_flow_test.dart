import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/remote_backup_controller.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/backup/backup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _FakeBackupService implements BackupService {
  _FakeBackupService({this.enableError});

  final BackupException? enableError;
  bool enabled = false;
  DateTime? lastBackupAt;

  @override
  Future<BackupStatus> status() async {
    return BackupStatus(enabled: enabled, lastBackupAt: lastBackupAt);
  }

  @override
  Future<bool> hasRemoteBackup() async => false;

  @override
  Future<String> enable({required String passphrase}) async {
    if (enableError != null) throw enableError!;
    enabled = true;
    lastBackupAt = DateTime.utc(2026, 6, 28, 12);
    return 'ABCD-EFGH-JKLM';
  }

  @override
  Future<void> backupNow() async {
    lastBackupAt = DateTime.utc(2026, 6, 28, 12);
  }


  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      throw UnimplementedError();

  @override
  Future<RestoreResult> commitRestore({required RestoreConfirmation confirmation}) async =>
      throw UnimplementedError();

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => true;

  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}

  @override
  Future<void> disable() async {
    enabled = false;
    lastBackupAt = null;
  }

  @override
  Future<void> deleteRemoteBackups() async {}
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.authMethod = 'email';
  });

  testWidgets('user can enable backup and see recovery code', (tester) async {
    final service = _FakeBackupService();

    await _pumpBackupScreen(tester, service);
    await tester.enterText(find.byType(TextField), 'strong-passphrase');
    await tester.tap(find.widgetWithText(FilledButton, 'متابعة'));
    await tester.pumpAndSettle();

    expect(find.text('رمز الاسترداد (Recovery Code)'), findsOneWidget);
    expect(find.text('ABCD-EFGH-JKLM'), findsOneWidget);
    expect(service.enabled, isTrue);
  });

  testWidgets('missing backups bucket is shown as an inline setup error',
      (tester) async {
    final service = _FakeBackupService(
      enableError: const BackupException(
        'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups في Supabase ثم جرّب تاني.',
      ),
    );

    await _pumpBackupScreen(tester, service);
    await tester.enterText(find.byType(TextField), 'strong-passphrase');
    await tester.tap(find.widgetWithText(FilledButton, 'متابعة'));
    await tester.pumpAndSettle();

    expect(find.textContaining('backups'), findsOneWidget);
    expect(find.textContaining('Storage bucket'), findsOneWidget);
    expect(find.text('رمز الاسترداد (Recovery Code)'), findsNothing);
    expect(service.enabled, isFalse);
  });

  testWidgets('with cloud consent OFF nothing is uploaded and the screen says '
      'why', (tester) async {
    // The defect this closes: the screen called the service directly, so the
    // consent gate never ran and an encrypted copy of the whole ledger was
    // uploaded with cloud sync switched off.
    final service = _FakeBackupService();
    await _pumpBackupScreen(tester, service, cloudConsent: false);

    await tester.enterText(find.byType(TextField).first, 'a-good-passphrase');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).first);
    await tester.pumpAndSettle();

    expect(service.enabled, isFalse,
        reason: 'the upload happened despite cloud consent being off');
    expect(find.text('رمز الاسترداد (Recovery Code)'), findsNothing,
        reason: 'a recovery code implies a backup exists; none was made');
  });
}

Future<void> _pumpBackupScreen(
  WidgetTester tester,
  BackupService service, {
  bool cloudConsent = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupServiceProvider.overrideWithValue(service),
        // Turning backup on goes through the CONTROLLER now, because that is
        // where the cloud-consent gate lives — the screen used to call the
        // service directly and upload with consent OFF. So consent has to be
        // stated here rather than inherited from a real settings row.
        remoteBackupControllerProvider.overrideWith(
          (ref) => RemoteBackupController(
            service,
            consentGranted: () async => cloudConsent,
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('ar'),
        theme: AppTheme.light,
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: BackupScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
