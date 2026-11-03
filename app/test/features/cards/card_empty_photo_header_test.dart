import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('empty cards keeps original art and add action reachable below photo at 2x $language dark$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final fonts = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await fonts.load();
        });
        await tester.pumpWidget(ProviderScope(overrides: [
          baseCurrencyProvider.overrideWith((ref) async => 'EGP'),
          accountsProvider.overrideWith((ref) async => const <AccountEntity>[]),
          allCardsProvider.overrideWith((ref) async => const <CardEntity>[]),
          accountCardGroupsProvider.overrideWith((ref) async =>
              const CardGrouping(byAccount: {}, unassigned: <CardSummary>[])),
        ], child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const MyCardsScreen(),
        )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final l10n = AppL10n.of(tester.element(find.byType(MyCardsScreen)));
        expect(find.byWidgetPredicate((widget) => widget is QirshIllustration &&
            widget.name == 'accounts'), findsOneWidget);
        final add = find.widgetWithText(FilledButton, l10n.cardAddCardCta);
        expect(add, findsOneWidget);
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        expect(add.hitTestable(), findsOneWidget);
        expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
