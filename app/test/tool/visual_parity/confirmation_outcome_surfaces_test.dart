import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/confirmation_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'confirmation-visual-memory';
  @override
  Future<String?> readStoredKey() async => 'confirmation-visual-memory';
}
Future<Map<String, Object>> snapshot(AppDatabase db) async {
  final tables = await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {for (final table in tables) table.read<String>('name'):
    (await db.customSelect('SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid').get()).map((r) => r.data).toList()};
}
void main() {
  for (final key in visualParityConfirmationOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key $language dark=$dark keeps actual pending row and parent writer', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          late ProviderContainer parent;
          await tester.runAsync(() async {
            final loader = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await loader.load();
            db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys(), initialLanguage: 'ar');
            parent = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
            final at = DateTime.utc(2026, 10, 10);
            final account = await parent.read(accountRepositoryProvider).create(AccountEntity(
              id: 'qa-confirm-account', name: 'QA confirmation', currency: 'EGP', type: AccountType.bank,
              isDefault: true, sortOrder: 0, createdAt: at, updatedAt: at,
              initialBalanceMoney: Money(0, 'EGP'), currentBalanceMoney: Money(0, 'EGP')));
            await parent.read(transactionRepositoryProvider).saveTransaction(transaction: TransactionEntity(
              id: visualParityConfirmationTransactionId, accountId: account.id, currency: 'EGP', amountMoney: Money(12550, 'EGP'),
              type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card, occurredAt: at,
              rawMessage: 'Synthetic message only', rawMerchant: 'QA merchant', parseConfidence: .6,
              status: TransactionStatus.pending, createdAt: at, updatedAt: at, direction: TransactionDirectionEntity.debit), categoryKey: 'groceries');
          });
          addTearDown(() async { parent.dispose(); await db.close(); });
          final repository = parent.read(transactionRepositoryProvider);
          final usecase = parent.read(confirmTransactionUseCaseProvider);
          final before = await tester.runAsync(() => snapshot(db));
          final old = visualParityConfirmationOutcomeEvents()[key] ?? 0;
          await tester.pumpWidget(UncontrolledProviderScope(container: parent,
            child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
                onPressed: () async => openVisualParityConfirmationOutcome(context, ref, key),
                child: const Text('Open confirmation')))))));
          await tester.tap(find.text('Open confirmation'));
          await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pumpAndSettle();
          expect(find.text(language == 'en' ? 'Groceries' : 'بقالة'), findsWidgets);
          final l10n = AppL10n.of(tester.element(find.byType(AppButton).first));
          final badge = find.text(l10n.txnPendingReview);
          final badgeElement = tester.element(badge);
          Color? background;
          badgeElement.visitAncestorElements((ancestor) {
            if (ancestor.widget case DecoratedBox(decoration: final BoxDecoration decoration)) {
              if (decoration.color != null) {
                background = decoration.color;
                return false;
              }
            }
            return true;
          });
          final colors = Theme.of(badgeElement).extension<AppColors>()!;
          final fill = Color.alphaBlend(background!, colors.surface);
          double ratio(Color ink) {
            final a = Color.alphaBlend(ink, fill).computeLuminance();
            final b = fill.computeLuminance();
            return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
          }
          final paragraph = tester.renderObject<RenderParagraph>(badge);
          final actualInk = (paragraph.text as TextSpan).style!.color!;
          final actualIcon = tester.widget<Icon>(find.descendant(
            of: find.ancestor(of: badge, matching: find.byType(Row)).first,
            matching: find.byType(Icon),
          ).first);
          final textRatio = ratio(actualInk);
          final iconRatio = ratio(actualIcon.color!);
          // Keep lifecycle/SQL assertions running even for the baseline paint defect.
          final button = find.byWidgetPredicate((widget) => widget is AppButton && widget.label == l10n.txdConfirmTx);
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          await tester.tap(button);
          await tester.pump(const Duration(milliseconds: 300));
          expect(visualParityConfirmationOutcomeEvents()[key], old + 1);
          if (key.endsWith('Saving')) {
            expect(tester.widget<AppButton>(button).loading, isTrue);
            expect(tester.widget<AppButton>(button).onPressed, isNull);
            await tester.tap(button, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 200));
            expect(visualParityConfirmationOutcomeEvents()[key], old + 1);
          } else {
            expect(find.text(l10n.ctsConfirmFailed), findsOneWidget);
            expect(tester.widget<AppButton>(button).loading, isFalse);
            expect(tester.widget<AppButton>(button).onPressed, isNotNull);
            await tester.tap(button);
            await tester.pump(const Duration(milliseconds: 300));
            expect(visualParityConfirmationOutcomeEvents()[key], old + 2);
            await tester.pump(const Duration(seconds: 7));
          }
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(identical(parent.read(transactionRepositoryProvider), repository), isTrue);
          expect(identical(parent.read(confirmTransactionUseCaseProvider), usecase), isTrue);
          expect(tester.takeException(), isNull);
          final sheetContext = tester.element(find.byType(AppButton).first);
          Navigator.of(sheetContext).pop();
          await tester.pumpAndSettle();
          expect(find.text('Open confirmation'), findsOneWidget);
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(tester.takeException(), isNull);
          expect(textRatio, greaterThanOrEqualTo(4.5), reason: 'Actual pending badge text contrast');
          expect(iconRatio, greaterThanOrEqualTo(3), reason: 'Actual pending badge icon contrast');
        });
      }
    }
  }
}
