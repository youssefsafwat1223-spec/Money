import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// A chart axis is the easiest place in an app for an untranslated string to
/// hide. The daily-spend chart carried its own `const _initials` list of Arabic
/// letters, so an English reader saw «ن ث ر خ ج س ح» under the bars with only
/// "Today" in their language.
///
/// It survived a full bilingual route walk because single characters look like
/// noise in a string scan — they were recorded as "avatar initials" and
/// explained away. Only looking at the rendered screen caught it.
void main() {
  Future<List<String>> initialsIn(WidgetTester tester, String lang) async {
    late List<String> out;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(lang),
      home: Builder(builder: (context) {
        // Monday 2026-09-14 through Sunday 2026-09-20.
        out = [
          for (var i = 0; i < 7; i++)
            Formatters.weekdayInitial(context, DateTime(2026, 9, 14 + i)),
        ];
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('weekday initials follow the reader', (tester) async {
    expect(await initialsIn(tester, 'ar'),
        ['ن', 'ث', 'ر', 'خ', 'ج', 'س', 'ح']);
    expect(await initialsIn(tester, 'en'),
        ['M', 'T', 'W', 'T', 'F', 'S', 'S']);
  });

  testWidgets('no Arabic reaches the English axis', (tester) async {
    final arabicScript = RegExp(r'[؀-ۿ]');
    for (final label in await initialsIn(tester, 'en')) {
      expect(arabicScript.hasMatch(label), isFalse,
          reason: 'the English chart axis still reads Arabic: $label');
    }
  });

  test('the chart no longer carries its own weekday table', () {
    // The defect was a private `const _initials` beside the painter. A second
    // copy is how this regresses — the locale-aware helper already existed and
    // was already correct; the chart simply did not use it.
    final card =
        File('lib/features/dashboard/widgets/daily_spend_card.dart')
            .readAsStringSync();
    expect(card, isNot(contains("'ن', 'ث', 'ر'")),
        reason: 'the chart has its own Arabic weekday table again');
    expect(card, contains('Formatters.weekdayInitial'));
  });
}
