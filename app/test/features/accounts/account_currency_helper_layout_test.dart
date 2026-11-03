import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.9411764705882353]) {
        testWidgets('locked currency explanation stays complete $language dark=$dark scale=$scale', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          for (final family in ['Vazirmatn', 'Alexandria', 'IBMPlexSansArabic']) {
            final loader = FontLoader(family);
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
            }
            await loader.load();
          }
          final at = DateTime.utc(2026, 11, 1);
          final account = AccountEntity(id: 'qa-locked-layout', name: 'QA account',
            currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0,
            createdAt: at, updatedAt: at, initialBalanceMoney: Money(1, 'KWD'),
            currentBalanceMoney: Money(1, 'KWD'));
          await tester.pumpWidget(ProviderScope(overrides: [
            activeCurrenciesProvider.overrideWith((ref) async => []),
            accountHasTransactionsProvider.overrideWith((ref, id) => throw StateError('Balance lock requires no usage read')),
          ], child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
            home: Scaffold(body: SafeArea(child: AccountFormPanel(account: account))),
          )));
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('account-currency-field'));
          final l10n = AppL10n.of(tester.element(field));
          final explanation = find.text(l10n.afCurrencyLockedShort);
          await tester.ensureVisible(explanation);
          await tester.pumpAndSettle();
          expect(tester.renderObject<RenderParagraph>(explanation).didExceedMaxLines, isFalse,
            reason: 'The complete reason for the disabled currency must remain readable');
          final paragraph = tester.renderObject<RenderParagraph>(explanation);
          final background = Theme.of(tester.element(field)).extension<AppColors>()!.surface;
          final foreground = Color.alphaBlend(paragraph.text.style!.color!, background);
          final a = foreground.computeLuminance();
          final b = background.computeLuminance();
          final contrast = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
          expect(contrast, greaterThanOrEqualTo(4.5),
            reason: 'Explanatory copy must remain readable even when its input is disabled');
          expect(explanation.hitTestable(), findsOneWidget);
          expect(tester.widget<GlassDropdownField<String>>(field).onChanged, isNull);
          await tester.tap(field, warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(find.byType(RadioListTile<String>), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
