import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/sync_diagnostics_report.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/settings/sync_diagnostics_screen.dart';
import 'package:money_companion/features/settings/sync_status_providers.dart';
import 'package:money_companion/features/settings/sync_status_ui.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Widget _app(SyncStatus status, {String lang = 'en', Widget? home}) =>
    ProviderScope(
      overrides: [syncStatusProvider.overrideWith((ref) async => status)],
      child: MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: Locale(lang),
        home: home ?? const Scaffold(body: SyncStatusTile()),
      ),
    );

void main() {
  final cases = <(SyncStatus, String, String)>[
    (const SyncStatus(kind: SyncStatusKind.allSynced), 'All data synced',
        'تمت مزامنة كل البيانات'),
    (const SyncStatus(kind: SyncStatusKind.syncing), 'Syncing…',
        'جارٍ المزامنة…'),
    (const SyncStatus(kind: SyncStatusKind.waiting, count: 3),
        '3 changes waiting to sync', '3 تغييرات بانتظار المزامنة'),
    (const SyncStatus(kind: SyncStatusKind.consentOff, count: 2),
        'Cloud Sync is off — data stays on this device',
        'المزامنة السحابية متوقفة — بياناتك تبقى على هذا الجهاز'),
    (const SyncStatus(kind: SyncStatusKind.signedOut),
        'Signed out — data stays on this device',
        'لم تسجّل الدخول — بياناتك تبقى على هذا الجهاز'),
    (const SyncStatus(kind: SyncStatusKind.failed, count: 1),
        'Sync failed — Retry', 'فشلت المزامنة — إعادة المحاولة'),
    // WP-8
    (const SyncStatus(kind: SyncStatusKind.needsAttention, count: 2),
        'Needs your attention', 'تحتاج إلى انتباهك'),
    (const SyncStatus(kind: SyncStatusKind.waiting, count: 0),
        'Waiting to sync', 'بانتظار المزامنة'),
  ];

  for (final (status, en, ar) in cases) {
    testWidgets('settings row renders ${status.kind.name} (EN + AR)',
        (tester) async {
      await tester.pumpWidget(_app(status));
      await tester.pumpAndSettle();
      expect(find.text(en), findsOneWidget);
      await tester.pumpWidget(_app(status, lang: 'ar'));
      await tester.pumpAndSettle();
      expect(find.text(ar), findsOneWidget);
    });
  }

  testWidgets('tapping the row opens the sheet with categories + Retry',
      (tester) async {
    await tester.pumpWidget(_app(SyncStatus(
      kind: SyncStatusKind.failed,
      count: 3,
      waitingForConnection: 2,
      waitingForServer: 1,
      needsAttention: 3,
      stayFailed: 1,
      lastSuccessAt: DateTime.utc(2026, 6, 1, 10),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-status-tile')));
    await tester.pumpAndSettle();
    expect(find.text('Sync status'), findsOneWidget);
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(find.text('Waiting for server update'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.textContaining('stays failed'), findsOneWidget);
    expect(find.textContaining('Last successful sync'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-retry-button')), findsOneWidget);
  });

  testWidgets('allSynced sheet has no Retry button', (tester) async {
    await tester.pumpWidget(_app(const SyncStatus(kind: SyncStatusKind.allSynced)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-status-tile')));
    await tester.pumpAndSettle();
    expect(find.text('No successful sync yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-retry-button')), findsNothing);
  });

  testWidgets('needsAttention sheet lists the attention row and offers Retry',
      (tester) async {
    await tester.pumpWidget(_app(const SyncStatus(
      kind: SyncStatusKind.needsAttention,
      count: 3,
      needsAttention: 3,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-status-tile')));
    await tester.pumpAndSettle();
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-retry-button')), findsOneWidget);
    await tester.pumpWidget(_app(
        const SyncStatus(
            kind: SyncStatusKind.needsAttention, count: 3, needsAttention: 3),
        lang: 'ar'));
    await tester.pumpAndSettle();
    expect(find.text('تحتاج إلى انتباهك'), findsWidgets);
  });

  group('diagnostics', () {
    const auth = 'aaaa1111-2222-3333-4444-555566667777';
    const owner = 'bbbb1111-2222-3333-4444-555566668888';
    const smsText = 'Card 4111111111111234 charged SAR 1,234.56 at ACME COFFEE';

    SyncDiagnosticsReport report() => const SyncDiagnosticsReport([
          DiagnosticSection('Identity and replica', {
            'session present': 'yes',
            'replica owner matches session': 'no',
          }),
          DiagnosticSection('Pull', {'last pull stop': 'epochMismatch'}),
          DiagnosticSection('Empty', {}),
        ]);

    Future<void> pump(WidgetTester tester, SyncDiagnosticsReport r) =>
        tester.pumpWidget(ProviderScope(
          overrides: [syncDiagnosticsProvider.overrideWith((ref) async => r)],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const SyncDiagnosticsScreen(),
          ),
        ));

    testWidgets('screen renders the report sections, no uid in any form',
        (tester) async {
      await pump(tester, report());
      await tester.pumpAndSettle();
      expect(find.text('Identity and replica'), findsOneWidget);
      expect(find.text('replica owner matches session'), findsOneWidget);
      expect(find.text('no'), findsOneWidget);
      expect(find.text('epochMismatch'), findsOneWidget);
      expect(find.text('Empty'), findsNothing, reason: 'empty sections hide');
      expect(find.byKey(const ValueKey('run-sync-now')), findsOneWidget);
      expect(find.textContaining(auth), findsNothing);
      expect(find.textContaining(owner), findsNothing);
      expect(find.textContaining('aaaa…'), findsNothing);
    });

    testWidgets('Copy puts the redacted bundle (only) on the clipboard',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, report());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('copy-diagnostics')));
      await tester.pump();
      expect(copied, report().toRedactedText());
      expect(copied, contains('last pull stop: epochMismatch'));
      expect(copied, isNot(contains(smsText)));
    });

    test('the report never echoes free text', () {
      final rows = DiagnosticRows()..add('x', smsText);
      expect(rows.rows['x'], '[redacted]');
    });

    test('not reachable in release: guard + router registration', () {
      expect(syncDiagnosticsAvailable(debugMode: false), isFalse);
      expect(syncDiagnosticsAvailable(debugMode: true), isTrue);
      final router = File('lib/core/router/app_router.dart').readAsStringSync();
      final i = router.indexOf("path: '/settings/sync-diagnostics'");
      expect(i, greaterThan(0));
      expect(router.substring(i - 120, i), contains('if (syncDiagnosticsAvailable())'),
          reason: 'the diagnostics route must be registered behind the guard');
      final settings =
          File('lib/features/settings/settings_screen.dart').readAsStringSync();
      final j = settings.indexOf("context.push('/settings/sync-diagnostics')");
      expect(settings.lastIndexOf('if (kDebugMode)', j), greaterThan(0));
    });
  });
}
