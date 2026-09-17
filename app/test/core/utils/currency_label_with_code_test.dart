import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// The account list wrote `'${label} ($code)'` by hand. In Arabic that reads
/// naturally — «ريال (SAR)», a familiar name plus the ISO code. In English the
/// label IS the code, so it rendered **"SAR (SAR)"**: the same token twice.
///
/// Only a rendered screenshot showed it. A string test would have compared the
/// output to itself and agreed.
void main() {
  Future<String> render(WidgetTester tester, String lang, String code) async {
    late String out;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(lang),
      home: Builder(builder: (context) {
        out = Currency.labelWithCode(context, code);
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('English shows the code once, not twice', (tester) async {
    final en = await render(tester, 'en', 'SAR');
    expect(en, 'SAR');
    expect(en, isNot(contains('(')),
        reason: 'the English label is the code, so a parenthesised code '
            'repeats it');
  });

  testWidgets('Arabic keeps the name AND the code', (tester) async {
    final ar = await render(tester, 'ar', 'SAR');
    expect(ar, contains('('));
    expect(ar, endsWith('(SAR)'));
    expect(ar, isNot('SAR (SAR)'));
    // The Arabic half must actually be Arabic, or the collapse rule fired on
    // the wrong branch.
    expect(RegExp(r'[؀-ۿ]').hasMatch(ar), isTrue);
  });

  testWidgets('a lower-case code still collapses in English', (tester) async {
    expect(await render(tester, 'en', 'usd'), 'USD');
  });

  testWidgets('a currency with no Arabic name collapses in both',
      (tester) async {
    // An unknown code has no localized name in either language, so neither
    // should print it twice.
    for (final lang in ['ar', 'en']) {
      final out = await render(tester, lang, 'XTS');
      expect(out, isNot(contains('XTS (XTS)')),
          reason: 'unknown code duplicated under $lang: $out');
    }
  });
}
