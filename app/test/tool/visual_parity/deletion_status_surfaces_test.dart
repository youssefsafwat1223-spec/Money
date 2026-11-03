import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/deletion_status_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'deletion-presentation-only';
  @override
  Future<String?> readStoredKey() async => 'deletion-presentation-only';
}

class _Launch extends ConsumerWidget {
  const _Launch(this.value);
  final String value;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(body: TextButton(
    onPressed: () => openVisualParityDeletionStatus(context, ref, value),
    child: const Text('Open presentation')));
}

void main() {
  late AppDatabase db;
  final channels = <String>[];
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
    channels.clear();
    for (final name in ['com.youssefsafwat.mali/capture', 'plugins.it_nomads.com/flutter_secure_storage',
        'plugins.flutter.io/sign_in_with_apple']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async {
        channels.add('$name:${call.method}');
        throw StateError('No platform authority in presentation');
      });
    }
  });
  tearDown(() async => db.close());
  Future<Map<String, Object>> snapshot() async {
    final rows = await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
    return {for (final row in rows) row.read<String>('name'):
      (await db.customSelect('SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
          .map((r) => r.data).toList()};
  }

  const markers = {
    'Running': 'deleteAccountProgress', 'Pending': 'deleteAccountPending',
    'Unconfirmed': 'deleteAccountUnconfirmed', 'UnconfirmedStale': 'deleteAccountUnconfirmed',
    'Retryable': 'deleteAccountFailed', 'FinalFailure': 'deleteAccountFailed',
    'AdminBlocked': 'deleteAccountAdminBlocked', 'RateLimited': 'deleteAccountRateLimited',
    'Rejected': 'deleteAccountRejected', 'CleanupPending': 'deleteAccountLocalCleanupPending',
    'Completed': 'deleteAccountSuccess',
  };
  for (final language in ['ar', 'en']) {
    for (final entry in markers.entries) {
      testWidgets('deletion ${entry.key} $language presents status without authority or SQL changes', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final key = 'deletionPresentation${entry.key}';
        final before = await snapshot();
        final initial = visualParityDeletionStatusEvents();
        await tester.pumpWidget(ProviderScope(overrides: [
          appDatabaseProvider.overrideWithValue(db),
        ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: _Launch(key))));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open presentation'));
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(DeleteAccountScreen), findsOneWidget);
        final l10n = AppL10n.of(tester.element(find.byType(DeleteAccountScreen)));
        if (entry.key == 'Retryable' || entry.key == 'FinalFailure') {
          expect(find.text(entry.key == 'Retryable'
              ? l10n.deleteAccountFailed : l10n.deleteAccountFailedFinal), findsOneWidget);
          expect(find.byKey(const Key('deleteAccountRetry')),
              entry.key == 'Retryable' ? findsOneWidget : findsNothing);
        } else {
          expect(find.byKey(Key(entry.value)), findsOneWidget);
        }
        final events = visualParityDeletionStatusEvents();
        expect(events['${key}ResumePresentation'], (initial['${key}ResumePresentation'] ?? 0) + 1);
        expect(events['${key}StatusPresentation'], (initial['${key}StatusPresentation'] ?? 0) + 1);
        expect(events['${key}CompletionPresentationCallback'],
          entry.key == 'Completed' ? (initial['${key}CompletionPresentationCallback'] ?? 0) + 1
              : initial['${key}CompletionPresentationCallback']);
        expect(channels, isEmpty);
        expect(tester.takeException(), isNull);
        expect(await snapshot(), before);
        Navigator.of(tester.element(find.byType(DeleteAccountScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(DeleteAccountScreen), findsNothing);
        expect(await snapshot(), before);
        expect(channels, isEmpty);
      });
    }
  }
}
