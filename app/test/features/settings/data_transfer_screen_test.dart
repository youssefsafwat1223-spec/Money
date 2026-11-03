import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/exporting/export_file_protector.dart';
import 'package:money_companion/core/exporting/export_providers.dart';
import 'package:money_companion/core/exporting/managed_export_store.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
// Test the share platform boundary without opening a system share sheet.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:money_companion/features/settings/data_transfer_screen.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _ExportFixture implements DataPortabilityService {
  _ExportFixture({this.failPreparation = false});
  final bool failPreparation;
  int calls = 0;

  @override
  Future<ExportedFile> exportTransactionsCsv() async {
    calls++;
    if (failPreparation) throw StateError('synthetic_export_prepare_failure');
    return ExportedFile(name: 'qirsh.csv', mimeType: 'text/csv',
        bytes: Uint8List.fromList('synthetic,fixture\n'.codeUnits), recordCount: 1);
  }

  @override
  Future<ExportedFile> exportFinancialPackage() => throw StateError('unused');
  @override
  Future<ImportPreview> inspectFile(String path) => throw StateError('unused');
  @override
  Future<ImportResult> import(ImportPreview preview, ImportMode mode) =>
      throw StateError('unused');
}

class _RecordingStore extends ManagedExportStore {
  _RecordingStore(Directory base) : super(baseDirectory: () async => base,
      protector: const NoopExportFileProtector(), idGenerator: () => 'synthetic-export');
  final written = <ManagedExport>[];
  final disposed = <String>[];
  final disposal = Completer<void>();

  @override
  Future<ManagedExport> writeBytes(Uint8List bytes, {
    required String shareName, required String extension, required String mimeType,
  }) async {
    final export = await super.writeBytes(bytes, shareName: shareName,
        extension: extension, mimeType: mimeType);
    written.add(export);
    return export;
  }

  @override
  Future<void> dispose(ManagedExport export) async {
    disposed.add(export.id);
    await super.dispose(export);
    if (!disposal.isCompleted) disposal.complete();
  }
}

class _RefusingShare extends SharePlatform {
  final filesSeen = <String>[];
  @override
  Future<ShareResult> shareXFiles(List<XFile> files, {
    String? subject, String? text, Rect? sharePositionOrigin,
    List<String>? fileNameOverrides,
  }) async {
    filesSeen.addAll(files.map((f) => f.path));
    throw StateError('synthetic_share_failure');
  }
}

Future<void> _assertFailureToast(WidgetTester tester, String text) async {
  try {
    expect(find.text(text), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
  } finally {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('shows the three portability entry points and privacy warning',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [accountsProvider.overrideWith((ref) async => const [])],
      child:
          MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            locale: const Locale('ar'),
            theme: AppTheme.light, home: const DataTransferScreen()),
    ));
    await tester.pump();

    // The approved Export/Import groups and illustration make this a real
    // scrollable page. Verify each existing entry remains reachable rather
    // than assuming every lazy list child is mounted on arrival.
    for (final title in ['تصدير العمليات CSV', 'تصدير كل بيانات قرش ZIP', 'استيراد ملف']) {
      final entry = find.text(title);
      await tester.scrollUntilVisible(entry, 250, scrollable: find.byType(Scrollable).first);
      expect(entry, findsOneWidget);
      expect(entry.hitTestable(), findsOneWidget);
    }
    final privacy = find.textContaining('رسائل البنك الخام');
    await tester.scrollUntilVisible(privacy, 200, scrollable: find.byType(Scrollable).first);
    expect(privacy, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final prepareFailure in [true, false]) {
    testWidgets(prepareFailure
        ? 'export preparation failure retains page and releases busy with an alert'
        : 'share failure cleans actual managed artifact and releases busy with an alert',
        (tester) async {
      final directory = (await tester.runAsync(() =>
          Directory.systemTemp.createTemp('qirsh-transfer-notice-')))!;
      addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
      final service = _ExportFixture(failPreparation: prepareFailure);
      final store = _RecordingStore(directory);
      final share = _RefusingShare();
      final priorShare = SharePlatform.instance;
      SharePlatform.instance = share;
      addTearDown(() => SharePlatform.instance = priorShare);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          dataPortabilityServiceProvider.overrideWithValue(service),
          managedExportStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales, locale: const Locale('en'),
          theme: AppTheme.light, home: const DataTransferScreen()),
      ));
      await tester.pumpAndSettle();
      final l10n = AppL10n.of(tester.element(find.byType(DataTransferScreen)));
      final exportAction = find.text(l10n.dtxExportCsv);
      await tester.scrollUntilVisible(exportAction, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.runAsync(() async => tester.tap(exportAction));
      if (!prepareFailure) {
        // Let real file I/O and Flutter's fake-zone continuations both run;
        // blocking a fake-zone completer from runAsync stalls its own callback.
        for (var i = 0; i < 100 && !store.disposal.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(store.disposal.isCompleted, isTrue,
            reason: 'actual managed cleanup must finish before notice assertion');
      }
      await tester.pumpAndSettle();
      // Financial/service and artifact outcomes are asserted before notice style.
      expect(service.calls, 1);
      expect(find.byType(DataTransferScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(exportAction.hitTestable(), findsOneWidget);
      if (prepareFailure) {
        expect(store.written, isEmpty);
        expect(share.filesSeen, isEmpty);
        expect(store.disposed, isEmpty);
      } else {
        expect(store.written, hasLength(1));
        expect(share.filesSeen, [store.written.single.file.path]);
        expect(store.disposed, ['synthetic-export']);
        expect(await tester.runAsync(() => store.written.single.file.exists()), isFalse);
        expect(await tester.runAsync(() =>
            File('${store.written.single.file.parent.path}/synthetic-export.meta.json').exists()),
            isFalse);
      }
      await _assertFailureToast(tester,
          prepareFailure ? l10n.dtxReadFailed : l10n.dtxShareSheetFailed);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('replace confirmation owns its controller through route teardown',
      (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('ar'),
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                confirmed = await showReplaceConfirmationDialog(context);
              },
              child: const Text('open replace'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open replace'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'استبدال');
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
