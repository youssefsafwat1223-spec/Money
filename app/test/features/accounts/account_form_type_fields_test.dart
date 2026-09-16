import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  testWidgets('credit-card label reads "بطاقة ائتمانية" — in both languages',
      (tester) async {
    // `accountTypeLabel` takes a BuildContext now, because these four labels
    // come from the ARB. Asserting through a real element also proves the
    // English build says «Credit card» rather than falling back to Arabic.
    Future<Map<AccountType, String>> labelsIn(String lang) async {
      late Map<AccountType, String> out;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: Locale(lang),
        home: Builder(builder: (context) {
          out = {
            for (final t in AccountType.values) t: accountTypeLabel(context, t)
          };
          return const SizedBox();
        }),
      ));
      return out;
    }

    final ar = await labelsIn('ar');
    expect(ar[AccountType.card], 'بطاقة ائتمانية');
    expect(ar[AccountType.bank], 'بنك');
    expect(ar[AccountType.wallet], 'محفظة');
    expect(ar[AccountType.cash], 'نقدي');

    final en = await labelsIn('en');
    expect(en[AccountType.card], 'Credit card');
    expect(en[AccountType.bank], 'Bank');
    expect(en[AccountType.wallet], 'Wallet');
    expect(en[AccountType.cash], 'Cash');
  });

  testWidgets('form shows type-conditional fields and collapsed advanced',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((_) async => const []),
          activeCurrenciesProvider.overrideWith((_) async => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: const Locale('ar'),
          theme: AppTheme.light,
          home: _Opener(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();

    // Bank (default type) shows bank account number + starting balance.
    expect(find.text('رقم الحساب البنكي (اختياري)'), findsOneWidget);
    expect(find.text('الرصيد الافتتاحي (اختياري)'), findsOneWidget);
    // Advanced collapsed by default.
    expect(find.text('خيارات متقدمة'), findsOneWidget);
    expect(find.text('استبعاد من الإجماليات'), findsNothing);

    // Switch to Credit Card → credit fields appear.
    await tester.tap(find.text('بطاقة ائتمانية'));
    await tester.pumpAndSettle();
    expect(find.text('الحد الائتماني (اختياري)'), findsOneWidget);
    expect(find.text('يوم السداد (1–31، اختياري)'), findsOneWidget);
    expect(find.text('رقم الحساب البنكي (اختياري)'), findsNothing);

    // Expand advanced.
    await tester.tap(find.text('خيارات متقدمة'));
    await tester.pumpAndSettle();
    expect(find.text('استبعاد من الإجماليات'), findsOneWidget);
  });
}

class _Opener extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showAccountForm(context, ref),
          child: const Text('افتح'),
        ),
      ),
    );
  }
}
