import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/backup/backup_screen.dart';

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
  Future<void> restoreFromBackup({required String passphrase}) async {}

  @override
  Future<void> disable() async {
    enabled = false;
    lastBackupAt = null;
  }
}

void main() {
  setUp(() {
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
}

Future<void> _pumpBackupScreen(
  WidgetTester tester,
  BackupService service,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
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
