import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/section_photo_header.dart';
import 'package:money_companion/features/common/app_header.dart';
import 'package:money_companion/features/common/app_screen_scaffold.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['en', 'ar']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        for (final pushed in [false, true]) {
          testWidgets('section photo keeps controls and content reachable $language dark$dark scale$scale pushed$pushed', (tester) async {
            tester.view.physicalSize = const Size(375, 667);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 44, bottom: 20);
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final font = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await font.load();
            });
            var tapped = 0;
            final header = AppHeader(
              title: language == 'ar' ? 'الحسابات والمحافظ' : 'Accounts & wallets',
              sectionPhoto: QirshSectionPhoto.accounts,
              leading: const BackButton(color: Colors.white),
              action: IconButton(tooltip: 'Add account', onPressed: () => tapped++,
                icon: const Icon(Icons.add, color: Colors.white)),
            );
            final body = ListView(children: const [Text('Original account balances'), SizedBox(height: 900)]);
            await tester.pumpWidget(MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
              home: pushed
                  ? Scaffold(appBar: header, body: body)
                  : AppScreenScaffold(header: header, body: body),
            ));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('Original account balances'), findsOneWidget);
            final action = find.byTooltip('Add account');
            final bounds = tester.getRect(action);
            expect(bounds.top, greaterThanOrEqualTo(44));
            expect(bounds.bottom, lessThan(667));
            await tester.tap(action);
            await tester.pump();
            expect(tapped, 1);
            expect(find.byType(BackButton), findsOneWidget);
            await tester.drag(find.byType(ListView), const Offset(0, -200));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
