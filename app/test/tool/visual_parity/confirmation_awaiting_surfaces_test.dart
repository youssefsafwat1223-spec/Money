import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/confirmation_awaiting_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-edit-parent-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-edit-parent-memory';
}

Future<bool>? _opening;

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
      body: TextButton(
          onPressed: () {
            _opening =
                openVisualParityConfirmationAwaiting(context, ref, keyName);
          },
          child: const Text('Open edit fixture')));
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

Future<void> _settle(WidgetTester tester) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 150));
}

void main() {
  late AppDatabase parent;
  final nativeCalls = <String>[];
  setUp(() async {
    parent = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
    nativeCalls.clear();
    for (final channel in [
      'plugins.flutter.io/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'com.youssefsafwat.mali/capture',
      'plugins.flutter.io/firebase_messaging',
      'plugins.flutter.io/google_mobile_ads'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
        nativeCalls.add('$channel:${call.method}');
        return null;
      });
    }
  });
  tearDown(() async => parent.close());
  for (final key in visualParityConfirmationAwaitingKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('actual $key draft $language dark=$dark', (tester) async {
          var httpCalls = 0;
          await HttpOverrides.runZoned(() async {
            tester.view.physicalSize = const Size(375, 667);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final font = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(
                    rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await font.load();
            });
            final parentBefore = await tester.runAsync(() => _snapshot(parent));
            final feeCase = key == 'confirmationActualFeeNotice';
            final events = visualParityConfirmationAwaitingEvents();
            await tester.pumpWidget(ProviderScope(
                overrides: [appDatabaseProvider.overrideWithValue(parent)],
                child: MaterialApp(
                    theme: dark ? AppTheme.dark : AppTheme.light,
                    locale: Locale(language),
                    supportedLocales: AppL10n.supportedLocales,
                    localizationsDelegates: AppL10n.localizationsDelegates,
                    home: _Launch(key))));
            final outer = tester.state<NavigatorState>(find.byType(Navigator));
            final parentContainer =
                ProviderScope.containerOf(tester.element(find.byType(_Launch)));
            final writer = parentContainer.read(transactionRepositoryProvider);
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              await _settle(tester);
            });
            await tester.runAsync(() async {
              await tester.tap(find.text('Open edit fixture'));
              expect(await _opening, isTrue);
            });
            for (var i = 0; i < 5; i++) {
              await _settle(tester);
            }
            final field = find.byType(TextField);
            expect(field, findsOneWidget);
            final context = tester.element(field);
            final l10n = AppL10n.of(context);
            final childContainer = ProviderScope.containerOf(context);
            final child = childContainer.read(appDatabaseProvider);
            expect(child, isNot(same(parent)));
            final repository =
                childContainer.read(transactionRepositoryProvider);
            final rows = (await tester.runAsync(() => repository.getAll()))!;
            expect(rows, hasLength(feeCase ? 2 : 1));
            final actual = rows
                .singleWhere((tx) => tx.status == TransactionStatus.pending);
            if (!feeCase) expect(actual.id, 'qa-confirm-awaiting');
            final home = feeCase ? 'SAR' : 'EGP';
            final foreign = feeCase ? 'USD' : 'KWD';
            final minor = feeCase ? 9900 : 12345;
            expect(actual.amountMoney, Money.zero(home));
            expect(actual.foreignMoney, Money(minor, foreign));
            expect(actual.foreignCurrency, foreign);
            final setupReceipt =
                visualParityConfirmationAwaitingReceipts()[key]!;
            expect(setupReceipt['actualCloudProcessingEnabled'], isFalse);
            expect(setupReceipt['transactionId'], actual.id);
            if (feeCase) {
              final fee = rows.singleWhere(
                  (tx) => tx.status == TransactionStatus.confirmed);
              expect(fee.id, isNot(actual.id));
              expect(fee.amountMoney, Money(744, 'SAR'));
              expect(fee.accountId, actual.accountId);
              expect(fee.foreignMoney, isNull);
              expect(setupReceipt['feeId'], fee.id);
              expect(setupReceipt['feeMinor'], 744);
              expect(setupReceipt['feeCurrency'], 'SAR');
              expect(setupReceipt['feeStatus'], 'confirmed');
              expect(setupReceipt['actualOutcome'], 'added');
              expect(setupReceipt['secondaryOutcome'], 'added');
              expect(setupReceipt['actualDisposition'], 'requestConfirmation');
              expect(setupReceipt['aiFailureReason'], 'no_ai_client');
              expect(find.text(l10n.ctsFeeAlsoAdded('7.44', 'SAR')),
                  findsOneWidget);
              expect(
                  visualParityConfirmationAwaitingEvents()[
                      '${key}ActualIngest'],
                  (events['${key}ActualIngest'] ?? 0) + 1);
              final raw = (await tester.runAsync(() =>
                  child.customSelect('SELECT * FROM transactions').get()))!;
              expect(raw, hasLength(2));
              for (final tx in [actual, fee]) {
                final row =
                    raw.singleWhere((row) => row.read<String>('id') == tx.id);
                expect(
                    row.read<int>('amount_minor'), tx.amountMoney.minorUnits);
                expect(row.read<String>('currency'), tx.currency);
                expect(row.read<String>('status'), tx.status.name);
              }
            } else {
              expect(setupReceipt['feeId'], isNull);
            }
            expect(actual.status, TransactionStatus.pending);
            expect(actual.pricingState, TransactionPricingState.awaitingFx);
            expect(find.text(feeCase ? '99.00 USD' : '12.345 KWD'),
                findsOneWidget);
            final hint = l10n.ctsForeignCurrencyHint(
                feeCase ? '99.00' : '12.345',
                foreign,
                Currency.label(context, home));
            expect(find.text(hint), findsOneWidget);
            final button = find.byWidgetPredicate((widget) =>
                widget is AppButton && widget.label == l10n.txdConfirmTx);
            expect(tester.widget<AppButton>(button).onPressed, isNotNull,
                reason:
                    'Public Confirm sheet genuinely enables pricing-on-confirm; never fabricate disabled state');
            final before = await tester.runAsync(() => _snapshot(child));
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            expect(field.hitTestable(), findsOneWidget);
            await tester.enterText(field, '12.34');
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
            expect(tester.widget<TextField>(field).controller!.text, '12.34');
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            expect(button.hitTestable(), findsOneWidget);
            expect(tester.widget<AppButton>(button).onPressed,
                isNotNull); // deliberately never pressed
            expect(await tester.runAsync(() => _snapshot(child)), before);
            expect(
                (await tester.runAsync(() => repository.getById(actual.id)))!
                    .amountMoney,
                Money.zero(home));
            expect(parentContainer.read(transactionRepositoryProvider),
                same(writer));
            expect(
                await tester.runAsync(() => _snapshot(parent)), parentBefore);
            expect(nativeCalls, isEmpty);
            outer.pop();
            for (var i = 0;
                i < 40 &&
                    (visualParityConfirmationAwaitingEvents()['${key}Closed'] ??
                            0) ==
                        (events['${key}Closed'] ?? 0);
                i++) {
              await _settle(tester);
            }
            expect(visualParityConfirmationAwaitingEvents()['${key}Closed'],
                (events['${key}Closed'] ?? 0) + 1);
            expect(
                visualParityConfirmationAwaitingEvents()[
                    '${key}AllSqlUnchanged'],
                (events['${key}AllSqlUnchanged'] ?? 0) + 1);
            expect(
                visualParityConfirmationAwaitingEvents()[
                        '${key}ForbiddenWrite'] ??
                    0,
                events['${key}ForbiddenWrite'] ?? 0);
            final receipt = visualParityConfirmationAwaitingReceipts()[key]!;
            expect(receipt['childAllSqlUnchanged'], isTrue);
            expect(receipt['phase'], 'closed');
            expect(receipt['amountMinor'], 0);
            expect(receipt['foreignMinor'], minor);
            expect(receipt['status'], 'pending');
            expect(
                await tester.runAsync(() => _snapshot(parent)), parentBefore);
            expect(tester.takeException(), isNull);
            expect(httpCalls, 0);
          }, createHttpClient: (context) {
            httpCalls++;
            throw StateError('network construction forbidden');
          });
        });
      }
    }
  }
  testWidgets('unknown edit key accesses no provider', (tester) async {
    bool? handled;
    final events = visualParityConfirmationAwaitingEvents();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider
              .overrideWith((ref) => throw StateError('must not read provider'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityConfirmationAwaiting(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(visualParityConfirmationAwaitingEvents(), events);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file parent rejected before any child fixture', (tester) async {
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('qirsh-edit-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/parent.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityConfirmationAwaitingEvents();
    Object? rejection;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityConfirmationAwaiting(
                            context, ref, 'confirmationAwaitingPricing');
                      } catch (error) {
                        rejection = error;
                      }
                    },
                    child: const Text('File'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('File'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(rejection, isA<StateError>());
    expect(visualParityConfirmationAwaitingEvents(), events);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
