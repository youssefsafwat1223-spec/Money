import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _NoAccounts implements AccountRepository {
  @override
  Future<AccountEntity?> getDefault() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('manual save is reachable above keyboard: $lang dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.reset);
        final catalog = CategoryCatalog(const [
          CategoryEntity(id: 'category', key: 'groceries', nameAr: 'بقالة',
              icon: 'shopping-cart', color: '#16A37F', isIncome: false, sort: 0),
        ], languageCode: lang);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            categoryCatalogProvider.overrideWith((ref) async => catalog),
            accountsProvider.overrideWith((ref) async => const []),
            accountRepositoryProvider.overrideWithValue(_NoAccounts()),
          ],
          child: MaterialApp(
            locale: Locale(lang),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            theme: dark ? AppTheme.dark : AppTheme.light,
            home: Scaffold(body: Builder(builder: (context) => TextButton(
              onPressed: () => ManualTransactionSheet.show(context),
              child: const Text('open'),
            ))),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(ManualTransactionSheet));
        final l10n = AppL10n.of(context);
        final save = find.widgetWithText(FilledButton, l10n.mtAddTransaction);
        await tester.scrollUntilVisible(save, 160,
            scrollable: find.descendant(of: find.byType(ManualTransactionSheet),
                matching: find.byType(Scrollable)).first);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(367));
        await tester.tap(save);
        await tester.pump();
        expect(find.text(l10n.mtEnterValidAmount), findsOneWidget,
            reason: 'The visible Save still runs the existing amount validation.');
        expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
        expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
        expect(find.byType(ManualTransactionSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
