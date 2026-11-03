import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/ui/report_config_page.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _fixtureAccounts = StateProvider<List<AccountEntity>>((ref) => []);

AccountEntity _account(String id, String name) => AccountEntity(
      id: id,
      name: name,
      currency: 'EGP',
      type: AccountType.bank,
      isDefault: id == 'first',
      sortOrder: id == 'first' ? 0 : 1,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  final accounts = [_account('first', 'First EGP'), _account('second', 'Second EGP')];

  Widget harness(void Function(ReportRequest?) onResult, {
    ThemeData? theme,
    List<AccountEntity> accounts = const [],
  }) {
    return ProviderScope(
      overrides: <Override>[
        // Keep settings pending → the page falls back to its defaults, no DB.
        userSettingsProvider
            .overrideWith((ref) => Completer<UserSettingsEntity>().future),
        _fixtureAccounts.overrideWith((ref) => accounts),
        accountsProvider.overrideWith((ref) async => ref.watch(_fixtureAccounts)),
      ],
      child: MaterialApp(
        // The page uses AppHeader, which reads the app's theme extension.
        theme: theme ?? AppTheme.light,
        // Its copy comes from the ARB now, so the delegates are part of the
        // contract under test.
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => onResult(await showReportConfigPage(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders controls and returns a monthly all-accounts request',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Sheet is shown (English, the default MaterialApp locale).
    expect(find.text('Create a financial report'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Privacy mode (hide amounts)'), findsOneWidget);

    await tester.ensureVisible(find.text('Create report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.period, isA<MonthlyPeriod>());
    expect(result!.scope, isA<AllAccountsScope>());
    expect(result!.languageCode, 'ar'); // default when settings pending
  });

  testWidgets('selecting weekly yields a WeeklyPeriod request', (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Create report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.period, isA<WeeklyPeriod>());
  });

  Future<void> openSingleAccount(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
  }

  Future<void> generate(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Create report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report'));
    await tester.pumpAndSettle();
  }

  testWidgets('single-account mode submits the visibly default first EGP account',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r, accounts: accounts));
    await openSingleAccount(tester);
    final picker = tester.widget<GlassDropdownField<String>>(
        find.byType(GlassDropdownField<String>));
    expect(picker.value, 'first');
    await generate(tester);
    expect(result, isNotNull);
    expect(result!.scope, isA<SingleAccountScope>());
    expect(result!.accountId, 'first');
  });

  testWidgets('explicitly selecting second account preserves exact scope',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r, accounts: accounts));
    await openSingleAccount(tester);
    await tester.tap(find.byType(GlassDropdownField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Second EGP'));
    await tester.pumpAndSettle();
    await generate(tester);
    expect(result!.scope, isA<SingleAccountScope>());
    expect(result!.accountId, 'second');
  });

  testWidgets('explicit all-account selection returns all-account scope',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r, accounts: accounts));
    await openSingleAccount(tester);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(GlassDropdownField<String>), findsNothing);
    await generate(tester);
    expect(result!.scope, isA<AllAccountsScope>());
    expect(result!.accountId, isNull);
  });

  testWidgets('single-account mode cannot generate with no accounts',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r));
    await openSingleAccount(tester);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create report'));
    expect(button.onPressed, isNull);
    expect(result, isNull);
  });

  testWidgets('removed selected account falls back to the actual visible first account',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r, accounts: accounts));
    await openSingleAccount(tester);
    await tester.tap(find.byType(GlassDropdownField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Second EGP'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(
        find.byType(GlassDropdownField<String>)));
    container.read(_fixtureAccounts.notifier).state = [accounts.first];
    await tester.pumpAndSettle();
    final picker = tester.widget<GlassDropdownField<String>>(
        find.byType(GlassDropdownField<String>));
    expect(picker.value, 'first');
    expect(find.text('First EGP'), findsOneWidget);
    await generate(tester);
    expect(result!.scope, isA<SingleAccountScope>());
    expect(result!.accountId, 'first');
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the final account disables single-account generation',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r, accounts: [accounts.first]));
    await openSingleAccount(tester);
    final container = ProviderScope.containerOf(tester.element(
        find.byType(GlassDropdownField<String>)));
    container.read(_fixtureAccounts.notifier).state = [];
    await tester.pumpAndSettle();
    expect(find.byType(GlassDropdownField<String>), findsNothing);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create report'));
    expect(button.onPressed, isNull);
    expect(result, isNull);
  });

  // §12-I: the configuration step is a full-page ROUTE now, not a bottom sheet.
  for (final theme in [AppTheme.light, AppTheme.dark]) {
    testWidgets('custom date picker has readable system icons in ${theme.brightness.name}',
        (tester) async {
      await tester.pumpWidget(harness((_) {}, theme: theme));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Custom'));
      final l10n = AppL10n.of(context);
      await tester.tap(find.text(l10n.rcCustom));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.rcPickRange));
      await tester.pumpAndSettle();
      final picker = find.byType(DateRangePickerDialog);
      expect(picker, findsOneWidget);
      final overlay = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.ancestor(of: picker,
          matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first);
      expect(overlay.value.statusBarBrightness,
          theme.brightness == Brightness.dark ? Brightness.dark : Brightness.light);
      // The full-screen picker renders its own AppBar, whose overlay region
      // takes precedence over the builder's surrounding region on iOS.
      final pickerBar = find.descendant(of: picker, matching: find.byType(AppBar));
      expect(pickerBar, findsOneWidget);
      final pickerStyle = Theme.of(tester.element(pickerBar)).appBarTheme.systemOverlayStyle;
      expect(pickerStyle?.statusBarBrightness,
          theme.brightness == Brightness.dark ? Brightness.dark : Brightness.light);
      expect(pickerStyle?.statusBarIconBrightness,
          theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('config opens as a full-page route, not a bottom sheet',
      (tester) async {
    await tester.pumpWidget(harness((_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // No sheet surface anywhere...
    expect(find.byType(BottomSheet), findsNothing);
    // ...and the page is a real route with its own Scaffold + app bar.
    expect(find.text('Create a financial report'), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    // Back navigation exists (the route can be popped).
    expect(find.byType(BackButton), findsOneWidget);
  });
}
