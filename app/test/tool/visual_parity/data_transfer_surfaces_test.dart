import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/settings/data_transfer_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/data_transfer_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'transfer-qa-memory';
  @override
  Future<String?> readStoredKey() async => 'transfer-qa-memory';
}

class _OriginalPicker extends FilePickerPlatform {}

late BuildContext _hostContext;
late WidgetRef _hostRef;
Future<bool>? _opening;
final _events = <String>[];

class _Launch extends ConsumerWidget {
  const _Launch(this.surface);
  final String surface;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _hostContext = context;
    _hostRef = ref;
    return Scaffold(
        body: TextButton(
            onPressed: () {
              _opening = openVisualParityDataTransferSurface(
                  context, ref, surface,
                  onEvent: _events.add);
              _opening!.ignore();
            },
            child: const Text('Open fixture')));
  }
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  };
}

Future<void> _settle(WidgetTester tester, {bool reading = false}) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump(const Duration(milliseconds: 450));
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _host(WidgetTester tester, AppDatabase db, String key,
    {String language = 'en', bool dark = false}) async {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final fonts = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await fonts.load();
  });
  await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        localeProvider.overrideWithValue(Locale(language)),
      ],
      child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: _Launch(key))));
  await _settle(tester);
  addTearDown(() async {
    // Let production AppToast's three-second auto-dismiss finish while mounted.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });
}

Future<void> _open(WidgetTester tester, {bool reading = false}) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Open fixture'));
    expect(await _opening, true);
  });
  await _settle(tester, reading: reading);
  // Real file IO and repository awaits resume between Flutter frames.
  for (var attempt = 0; attempt < 12; attempt++) {
    await _settle(tester, reading: reading);
    if (reading || find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 24; attempt++) {
    if (target.evaluate().isNotEmpty) {
      final rect = tester.getRect(target.first);
      if (rect.center.dy > 105 &&
          rect.center.dy < 750 &&
          target.hitTestable().evaluate().isNotEmpty) {
        return;
      }
      await tester.drag(
          find.byType(ListView), Offset(0, rect.center.dy < 105 ? 260 : -260));
    } else {
      await tester.drag(find.byType(ListView), const Offset(0, -260));
    }
    await tester.pumpAndSettle();
  }
  throw StateError('Real public control not reachable: $target');
}

Future<void> _close(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(DataTransferScreen))).pop();
  await _settle(tester);
  // Production toast timers belong to the root overlay, beyond this route.
  await tester.pump(const Duration(seconds: 4));
}

void main() {
  late AppDatabase db;
  late FilePickerPlatform actualOriginal;
  late FilePickerPlatform sentinel;
  final nativeCalls = <String>[];
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
    // A preexisting financial row must remain byte-for-byte untouched.
    final now = DateTime.utc(2026, 10, 5);
    await DriftAccountRepository(db).create(AccountEntity(
        id: 'protected-account',
        name: 'Protected account',
        type: AccountType.bank,
        currency: 'EGP',
        initialBalanceMoney: Money(10025, 'EGP'),
        currentBalanceMoney: Money(10025, 'EGP'),
        isDefault: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now));
    actualOriginal = FilePickerPlatform.instance;
    sentinel = _OriginalPicker();
    FilePickerPlatform.instance = sentinel;
    _events.clear();
    nativeCalls.clear();
    for (final channel in [
      'dexterous.com/flutter/local_notifications',
      'com.youssefsafwat.mali/capture',
      'plugins.flutter.io/firebase_messaging',
      'plugins.flutter.io/google_mobile_ads',
      'miguelruivo.flutter.plugins.filepicker'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
        nativeCalls.add('$channel:${call.method}');
        return null;
      });
    }
  });
  tearDown(() async {
    expect(FilePickerPlatform.instance, same(sentinel));
    FilePickerPlatform.instance = actualOriginal;
    await db.close();
  });
  for (final key in visualParityDataTransferSurfaceKeys.take(3)) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            '$key actual public pipeline preserves all SQL $language dark$dark',
            (tester) async {
          final before = await _snapshot(db);
          await _host(tester, db, key, language: language, dark: dark);
          await _open(tester, reading: key == 'dataTransferReading');
          final context = tester.element(find.byType(DataTransferScreen));
          final l10n = AppL10n.of(context);
          expect(_events, contains('${key}PickerRequested'));
          expect(FilePickerPlatform.instance, isNot(same(sentinel)));
          String? filePath;
          if (key == 'dataTransferReading') {
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(find.text(l10n.dtxImportPreview), findsNothing);
          } else {
            final selected = await tester.runAsync(() => FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['csv', 'zip'],
                allowMultiple: false,
                withData: false));
            filePath = selected!.files.single.path!;
            expect(
                File(filePath).parent.path, contains('qirsh-visual-transfer-'));
            if (key == 'dataTransferBadFile') {
              expect(find.text(l10n.dpeCsvDuplicateColumns), findsOneWidget);
              expect(find.text(l10n.dtxImportPreview), findsNothing);
              expect(find.byType(CircularProgressIndicator), findsNothing);
            } else {
              expect(find.text(l10n.dtxImportPreview), findsOneWidget);
              final service = ProviderScope.containerOf(context)
                  .read(dataPortabilityServiceProvider);
              final preview =
                  await tester.runAsync(() => service.inspectFile(filePath!));
              expect(preview!.format, ImportFormat.genericCsv);
              expect(preview.totalRows, 1);
              expect(preview.hasErrors, false);
              expect(preview.canReplace, false);
              expect(preview.defaultAccountId, 'protected-account');
              expect(preview.sampleRows.single['amount'], '125.50');
              expect(preview.sampleRows.single['currency'], 'EGP');
              expect(preview.duplicateRecordIds, isEmpty);
              await tester.scrollUntilVisible(
                  find.text(l10n.dtxConfirmImport), 250);
              expect(find.text(l10n.dtxConfirmImport), findsOneWidget);
              // Deliberately never tap Confirm: inspection is read-only.
            }
          }
          expect(await tester.runAsync(() => _snapshot(db)), before);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
          await _close(tester);
          expect(FilePickerPlatform.instance, same(sentinel));
          expect(_events, contains('${key}Closed'));
          if (filePath != null) {
            expect(await tester.runAsync(() => File(filePath!).parent.exists()),
                false);
          }
          expect(await tester.runAsync(() => _snapshot(db)), before);
          // A second complete route proves the lease and picker are reusable.
          await _open(tester, reading: key == 'dataTransferReading');
          await _close(tester);
          expect(await tester.runAsync(() => _snapshot(db)), before);
        });
      }
    }
  }
  testWidgets('a second route cannot steal a held picker; disposal releases it',
      (tester) async {
    await _host(tester, db, 'dataTransferReading');
    await _open(tester, reading: true);
    final leased = FilePickerPlatform.instance;
    await tester.runAsync(() async {
      await expectLater(
          openVisualParityDataTransferSurface(
              _hostContext, _hostRef, 'dataTransferImportPreview'),
          throwsStateError);
    });
    expect(FilePickerPlatform.instance, same(leased));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    expect(FilePickerPlatform.instance, same(sentinel));
    expect(
        _events.where((e) => e == 'dataTransferReadingClosed'), hasLength(1));
  });
  testWidgets(
      'file-backed admission failure restores picker and permits next memory route',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qirsh-transfer-guard-test-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    await _host(tester, disk, 'dataTransferImportPreview');
    await tester.runAsync(() async {
      await tester.tap(find.text('Open fixture'));
      await expectLater(_opening, throwsStateError);
    });
    expect(FilePickerPlatform.instance, same(sentinel));
    expect(find.byType(DataTransferScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    await _host(tester, db, 'dataTransferReading');
    await _open(tester, reading: true);
    await _close(tester);
  });
  testWidgets(
      'route opening error cleans its own CSV directory and releases picker',
      (tester) async {
    final before = await _snapshot(db);
    Future<Set<String>> directories() async => (await Directory.systemTemp
            .list()
            .where((entry) =>
                entry is Directory &&
                entry.path.split('/').last.startsWith('qirsh-visual-transfer-'))
            .map((entry) => entry.path)
            .toList())
        .toSet();
    final priorDirectories = await tester.runAsync(directories);
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
            builder: (context, child) =>
                const _Launch('dataTransferImportPreview'))));
    await tester.runAsync(() async {
      await tester.tap(find.text('Open fixture'));
      await expectLater(_opening, throwsA(isA<FlutterError>()));
    });
    expect(FilePickerPlatform.instance, same(sentinel));
    expect(await tester.runAsync(directories), priorDirectories);
    expect(await tester.runAsync(() => _snapshot(db)), before);
    // Recreate the host with its distinct provider override set.
    await tester.pumpWidget(const SizedBox.shrink());
    // The opening failure must not leave the global lease occupied.
    await _host(tester, db, 'dataTransferReading');
    await _open(tester, reading: true);
    await _close(tester);
  });
  for (final key in visualParityDataTransferSurfaceKeys.skip(3)) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key isolated real financial outcome $language dark$dark',
            (tester) async {
          final parentBefore = await _snapshot(db);
          await _host(tester, db, key, language: language, dark: dark);
          await _open(tester);
          final context = tester.element(find.byType(DataTransferScreen));
          final container = ProviderScope.containerOf(context);
          final child = container.read(appDatabaseProvider);
          expect(child, isNot(same(db)));
          final l10n = AppL10n.of(context);
          final before = (await tester.runAsync(() => _snapshot(child)))!;
          final service = container.read(dataPortabilityServiceProvider);
          final selected = (await tester.runAsync(() => FilePicker.pickFiles(
              type: FileType.custom, allowedExtensions: ['csv', 'zip'])))!;
          final path = selected.files.single.path!;
          final preview =
              (await tester.runAsync(() => service.inspectFile(path)))!;
          expect(
              preview.defaultAccountId,
              key == 'dataTransferGuestReplace'
                  ? isNull
                  : 'qa-transfer-account');
          expect((await container.read(accountsProvider.future)).single.name,
              'QA isolated EGP account');
          if (key == 'dataTransferInvalidPreview') {
            expect(preview.hasErrors, true);
            expect(
                preview.issues.single.code, ImportIssueCode.csvNeedsTwoColumns);
            final button = tester.widget<FilledButton>(
                find.widgetWithText(FilledButton, l10n.dtxConfirmImport));
            expect(button.onPressed, isNull);
          } else if (key == 'dataTransferDuplicatePolicy') {
            expect(preview.duplicateRecordIds, hasLength(1));
            expect(preview.hasErrors, false);
            await _reveal(tester, find.byType(SwitchListTile));
            expect(
                tester
                    .widget<SwitchListTile>(find.byType(SwitchListTile))
                    .value,
                false);
            await tester.tap(find.byType(SwitchListTile));
            await tester.pump();
            expect(
                tester
                    .widget<SwitchListTile>(find.byType(SwitchListTile))
                    .value,
                true);
            await tester.tap(find.byType(SwitchListTile));
            await tester.pump();
            expect(
                tester
                    .widget<SwitchListTile>(find.byType(SwitchListTile))
                    .value,
                false);
          } else if (key == 'dataTransferImportResult') {
            expect(preview.totalRows, 3);
            expect(preview.hasErrors, false); // row error, not file-level error
            expect(preview.duplicateRecordIds, hasLength(1));
            expect(
                preview.issues
                    .where((e) => e.severity == ImportIssueSeverity.error),
                hasLength(1));
            final original = (await tester.runAsync(() => child
                    .customSelect(
                        "SELECT * FROM transactions WHERE id='qa-transfer-existing-payment'")
                    .getSingle()))!
                .data;
            await _reveal(tester, find.text(l10n.dtxConfirmImport));
            await tester.tap(find.text(l10n.dtxConfirmImport));
            for (var attempt = 0; attempt < 20; attempt++) {
              await _settle(tester);
              if (find.text(l10n.dtxImportDone).evaluate().isNotEmpty) break;
            }
            await _reveal(tester, find.text(l10n.dtxImportDone));
            for (final label in [
              l10n.dtxAdded(1),
              l10n.dtxDuplicates(1),
              l10n.dtxQuarantined(0),
              l10n.dtxFailed(1)
            ]) {
              expect(find.text(label), findsOneWidget);
            }
            final transactions = await tester
                .runAsync(() => DriftTransactionRepository(child).getAll());
            expect(transactions, hasLength(2));
            final added = transactions!.singleWhere(
                (t) => t.source == TransactionSourceEntity.imported);
            expect(added.amountMoney, Money(12550, 'EGP'));
            expect(added.currency, 'EGP');
            expect(added.accountId, 'qa-transfer-account');
            expect(added.type, TransactionTypeEntity.payment);
            expect(added.rawMessage, '');
            expect(added.rawMerchant, 'QA newly imported market');
            expect(
                (await tester.runAsync(() => child
                        .customSelect(
                            "SELECT * FROM transactions WHERE id='qa-transfer-existing-payment'")
                        .getSingle()))!
                    .data,
                original);
            final after = (await tester.runAsync(() => _snapshot(child)))!;
            // Only actual transaction+merchant writes are expected here.
            final unchanged = Map<String, Object>.of(after)
              ..remove('transactions')
              ..remove('merchants');
            final oldUnchanged = Map<String, Object>.of(before)
              ..remove('transactions')
              ..remove('merchants');
            expect(unchanged, oldUnchanged);
          } else {
            expect(preview.format, ImportFormat.qirshPackage);
            expect(preview.canReplace, true);
            await _reveal(tester, find.text(l10n.dtxReplace));
            await tester.tap(find.text(l10n.dtxReplace));
            await tester.pump();
            await _reveal(tester, find.text(l10n.dtxConfirmImport));
            await tester.tap(find.text(l10n.dtxConfirmImport));
            await _settle(tester);
            expect(find.text(l10n.dtxConfirmReplace), findsOneWidget);
            await tester.enterText(find.byType(TextField), l10n.dtxReplace);
            await tester.pump();
            expect(
                tester
                    .widget<TextField>(find.byType(TextField))
                    .controller!
                    .text,
                l10n.dtxReplace);
            // Do not submit the real typed confirmation: only Cancel may close.
          }
          if (key == 'dataTransferGuestReplace') {
            await tester.tap(find.text(l10n.commonCancel));
            await _settle(tester);
          }
          if (key != 'dataTransferImportResult') {
            expect(await tester.runAsync(() => _snapshot(child)), before);
          }
          expect(await tester.runAsync(() => _snapshot(db)), parentBefore);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
          await _close(tester);
          expect(FilePickerPlatform.instance, same(sentinel));
          expect(
              await tester.runAsync(() => File(path).parent.exists()), false);
          expect(_events, contains('${key}Closed'));
          expect(await tester.runAsync(() => _snapshot(db)), parentBefore);
        });
      }
    }
  }
  for (final heldKey in visualParityDataTransferSurfaceKeys.skip(3)) {
    testWidgets('$heldKey shares the original global picker lease',
        (tester) async {
      await _host(tester, db, heldKey);
      await _open(tester);
      final leased = FilePickerPlatform.instance;
      await tester.runAsync(() async {
        await expectLater(
            openVisualParityDataTransferSurface(
                _hostContext, _hostRef, 'dataTransferReading'),
            throwsStateError);
      });
      expect(FilePickerPlatform.instance, same(leased));
      await _close(tester);
      expect(FilePickerPlatform.instance, same(sentinel));
      await _open(tester);
      await _close(tester);
    });
  }
}
