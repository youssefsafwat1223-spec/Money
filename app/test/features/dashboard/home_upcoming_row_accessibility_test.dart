import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/mali_card.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/dashboard/widgets/home_overview_cards.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final width in [375.0, 402.0]) {
        for (final scale in [1.9411764705882353, 2.14]) {
          testWidgets('upcoming row $language ${theme.brightness.name} width$width scale$scale shows full name date amount and due copy',
              (tester) async {
            tester.view.physicalSize = Size(width, 874);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final fonts = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await fonts.load();
            });
            final bill = BillEntity(id: 'synthetic-upcoming',
              name: language == 'ar' ? 'اشتراك نتفليكس العائلي السنوي' : 'Netflix Family annual subscription',
              amountMoney: Money(59989, 'KWD'), currency: 'KWD',
              type: BillType.subscription, frequency: BillFrequency.monthly,
              nextDueDate: DateTime(2026, 11, 2), reminderOn: true,
              isConfirmed: true, createdAt: DateTime(2026, 1, 1));
            var taps = 0;
            await tester.pumpWidget(ProviderScope(overrides: [
              remoteMerchantLogosAllowedProvider.overrideWithValue(false),
            ], child: MaterialApp(theme: theme, locale: Locale(language),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
              home: Scaffold(body: SingleChildScrollView(child: Padding(
                padding: const EdgeInsets.all(16),
                child: UpcomingPaymentsCard(bills: [bill], privacyMode: false,
                  now: DateTime(2026, 10, 31), onTap: () => taps++),
              ))),
            )));
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(UpcomingPaymentsCard));
            final l10n = AppL10n.of(context);
            final subtitle = Formatters.dateGroupLabel(bill.nextDueDate, context);
            final amount = '\u2066−59.989\u2069 ${Currency.label(context, 'KWD')}';
            for (final copy in [bill.name, subtitle, amount, l10n.txnInDays(2)]) {
              final finder = find.text(copy);
              expect(finder, findsOneWidget);
              await tester.ensureVisible(finder);
              await tester.pumpAndSettle();
              final paragraph = tester.renderObject<RenderParagraph>(finder);
              expect(paragraph.didExceedMaxLines, isFalse,
                  reason: 'Complete copy must render without ellipsis: $copy');
              final boxes = paragraph.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: copy.length),
                boxHeightStyle: BoxHeightStyle.tight, boxWidthStyle: BoxWidthStyle.tight);
              expect(boxes, isNotEmpty);
              // Glyph selections include real font descent outside a rounded
              // Text line box. Check the actual owning card's clipping bounds,
              // not an invented per-font overhang tolerance.
              final cardBounds = tester.getRect(find.ancestor(of: finder,
                  matching: find.byType(MaliCard)).first);
              final origin = paragraph.localToGlobal(Offset.zero);
              for (final box in boxes) {
                expect(origin.dx + box.left, greaterThanOrEqualTo(cardBounds.left - 0.01));
                expect(origin.dx + box.right, lessThanOrEqualTo(cardBounds.right + 0.01));
                expect(origin.dy + box.top, greaterThanOrEqualTo(cardBounds.top - 0.01));
                expect(origin.dy + box.bottom, lessThanOrEqualTo(cardBounds.bottom + 0.01));
              }
            }
            await tester.ensureVisible(find.text(bill.name));
            await tester.pumpAndSettle();
            await tester.tap(find.text(bill.name));
            expect(taps, 1);
            expect(bill.amountMoney, Money(59989, 'KWD'));
            expect(bill.nextDueDate, DateTime(2026, 11, 2));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
