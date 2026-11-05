import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/local_read_notice_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'local-read-notice-qa-memory';
  @override
  Future<String?> readStoredKey() async => 'local-read-notice-qa-memory';
}

Future<Map<String, Object>> snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  };
}

void main() {
  for (final key in visualParityLocalReadNoticeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            '$key $language dark$dark actual shell cleanup notice is status only',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          late ProviderContainer parent;
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
            db = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
            parent = ProviderContainer(
                overrides: [appDatabaseProvider.overrideWithValue(db)]);
            final at = DateTime.utc(2026, 11, 1);
            await parent.read(accountRepositoryProvider).create(AccountEntity(
                id: 'qa-local-read-account',
                name: 'QA real read balance',
                currency: 'KWD',
                type: AccountType.bank,
                isDefault: true,
                sortOrder: 0,
                createdAt: at,
                updatedAt: at,
                initialBalanceMoney: Money(12345, 'KWD'),
                currentBalanceMoney: Money(12345, 'KWD')));
            await parent.read(transactionRepositoryProvider).saveTransaction(
                transaction: TransactionEntity(
                    id: 'qa-local-read-transaction',
                    accountId: 'qa-local-read-account',
                    currency: 'KWD',
                    amountMoney: Money(1250, 'KWD'),
                    type: TransactionTypeEntity.payment,
                    source: TransactionSourceEntity.imported,
                    occurredAt: at,
                    rawMessage: 'Synthetic local-read notice QA',
                    rawMerchant: 'QA raw SELECT merchant',
                    parseConfidence: 1,
                    status: TransactionStatus.confirmed,
                    createdAt: at,
                    updatedAt: at,
                    direction: TransactionDirectionEntity.debit),
                categoryKey: 'groceries');
          });
          addTearDown(() async {
            parent.dispose();
            await db.close();
          });
          final before = await tester.runAsync(() => snapshot(db));
          final asrBefore = AutomaticSessionRecovery.diagnostic.value;
          final trailBefore = List<String>.of(AuthDiagnostics.entries.value);
          final repository = parent.read(accountRepositoryProvider);
          final logout =
              visualParityLocalReadNoticeEvents()['${key}LogoutStatusInput'] ??
                  0;
          final retry =
              visualParityLocalReadNoticeEvents()['${key}RetryStatusInput'] ??
                  0;
          final closed =
              visualParityLocalReadNoticeEvents()['${key}Closed'] ?? 0;
          final forbidden = visualParityLocalReadNoticeEvents()[
                  'localReadNoticeForbiddenReconnect'] ??
              0;
          Future<bool?>? opening;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityLocalReadNotice(
                                        context, ref, key));
                              },
                              child: const Text('Open local read notice')))))));
          await tester.tap(find.text('Open local read notice'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          final shell = find.byType(LocalReadShell);
          final shellContext = tester.element(shell);
          final child = ProviderScope.containerOf(shellContext);
          final data = await tester
              .runAsync(() => child.read(localReadSnapshotProvider.future));
          expect(data!.accounts.single.name, 'QA real read balance');
          expect(data.accounts.single.balance, '12.345');
          expect(data.transactions.single.title, 'QA raw SELECT merchant');
          expect(data.transactions.single.amount, '1.250');
          expect(find.text('QA raw SELECT merchant'), findsNothing,
              reason: 'recovery no longer displays the financial snapshot');
          final l10n = AppL10n.of(shellContext);
          await tester.tap(find.byKey(const Key('local_read_logout')));
          await tester.pumpAndSettle();
          expect(visualParityLocalReadNoticeEvents()['${key}LogoutStatusInput'],
              logout + 1);
          expect(find.byKey(const Key('sign_out_incomplete_notice')),
              findsOneWidget);
          expect(
              find.text(l10n.signOutCleanupIncompleteMessage), findsOneWidget);
          final retryButton =
              find.byKey(const Key('sign_out_incomplete_retry'));
          await tester.tap(retryButton);
          await tester.pump(const Duration(milliseconds: 300));
          expect(visualParityLocalReadNoticeEvents()['${key}RetryStatusInput'],
              retry + 1);
          if (key.endsWith('Pending')) {
            expect(tester.widget<TextButton>(retryButton).onPressed, isNull);
            await tester.tap(retryButton, warnIfMissed: false);
            await tester.pump();
            expect(
                visualParityLocalReadNoticeEvents()['${key}RetryStatusInput'],
                retry + 1);
          } else {
            expect(
                find.text(l10n.signOutCleanupStillIncomplete), findsOneWidget);
            expect(tester.widget<TextButton>(retryButton).onPressed, isNotNull);
            await tester.tap(retryButton);
            await tester.pump(const Duration(milliseconds: 300));
            expect(
                visualParityLocalReadNoticeEvents()['${key}RetryStatusInput'],
                retry + 2);
          }
          expect(find.textContaining('private_local_read_retry_failure'),
              findsNothing);
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(identical(parent.read(accountRepositoryProvider), repository),
              isTrue);
          await tester.tap(find.byKey(const Key('sign_out_incomplete_close')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('sign_out_incomplete_notice')),
              findsNothing);
          expect(shell, findsOneWidget);
          Navigator.of(tester.element(shell), rootNavigator: true).pop();
          await tester.pumpAndSettle();
          expect(
              visualParityLocalReadNoticeEvents()['${key}Closed'], closed + 1);
          expect(
              visualParityLocalReadNoticeEvents()[
                      'localReadNoticeForbiddenReconnect'] ??
                  0,
              forbidden);
          expect(find.text('Open local read notice'), findsOneWidget);
          expect(AutomaticSessionRecovery.diagnostic.value, asrBefore);
          expect(AuthDiagnostics.entries.value, trailBefore);
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown local-read notice key cannot read providers',
      (tester) async {
    final before = Map<String, int>.of(visualParityLocalReadNoticeEvents());
    Future<bool?>? opening;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () {
                          opening = tester.runAsync(() =>
                              openVisualParityLocalReadNotice(
                                  context, ref, 'unknown'));
                        },
                        child: const Text('Unknown notice')))))));
    await tester.tap(find.text('Unknown notice'));
    expect(await opening, isFalse);
    expect(visualParityLocalReadNoticeEvents(), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file-backed parent cannot open cleanup notice fixture',
      (tester) async {
    late Directory directory;
    late AppDatabase db;
    await tester.runAsync(() async {
      directory =
          await Directory.systemTemp.createTemp('qirsh-local-read-notice-');
      db = await AppDatabase.open(
          executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
          keyStore: _Keys());
    });
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => snapshot(db));
    final events = Map<String, int>.of(visualParityLocalReadNoticeEvents());
    final parent = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(parent.dispose);
    Future<void>? opening;
    Object? failure;
    await tester.pumpWidget(UncontrolledProviderScope(
        container: parent,
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () {
                          opening = tester.runAsync(() async {
                            try {
                              await openVisualParityLocalReadNotice(
                                  context, ref, 'localReadCleanupRetryFalse');
                            } catch (error) {
                              failure = error;
                            }
                          });
                        },
                        child: const Text('File notice')))))));
    await tester.tap(find.text('File notice'));
    await opening;
    expect(failure, isA<StateError>());
    expect(visualParityLocalReadNoticeEvents(), events);
    expect(await tester.runAsync(() => snapshot(db)), before);
    expect(find.text('File notice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
