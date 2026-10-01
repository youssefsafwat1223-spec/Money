import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../onboarding/setup_consent_step_test.dart' show SpyAccountRepo;

void main() {
  testWidgets('delete is refused up front when it is the only account',
      (tester) async {
    final now = DateTime.utc(2026);
    final only = AccountEntity(
      id: 'only',
      name: 'Only',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false, // exposes the delete button
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
    final repo = SpyAccountRepo()..accounts.add(only);
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(repo),
        accountsProvider.overrideWith((_) async => [only]),
        activeCurrenciesProvider.overrideWith((_) async => const []),
        accountHasTransactionsProvider('only').overrideWith((_) async => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('en'),
        theme: AppTheme.light,
        home: Scaffold(body: AccountFormPanel(account: only)),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('You cannot delete your last account.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
