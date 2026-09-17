import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/features/settings/data_portability_messages.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// Import/export failures are the messages a user reads when their data did NOT
/// move. Leaving them in one language is the same defect as leaving a button
/// untranslated, except it happens at the worst possible moment.
void main() {
  Future<Map<DataPortabilityError, String>> renderedIn(
      WidgetTester tester, String lang) async {
    late Map<DataPortabilityError, String> out;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(lang),
      home: Builder(builder: (context) {
        out = {
          for (final code in DataPortabilityError.values)
            code: dataPortabilityMessage(
              context,
              // A placeholder-bearing message must still render with an arg.
              DataPortabilityException('ARABIC-FALLBACK',
                  code: code, args: const ['X']),
            ),
        };
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('every error code renders in both languages', (tester) async {
    final arabicScript = RegExp(r'[؀-ۿ]');

    final ar = await renderedIn(tester, 'ar');
    final en = await renderedIn(tester, 'en');

    for (final code in DataPortabilityError.values) {
      // An unmapped code would fall through to the raw message, which is the
      // exact failure this switch exists to prevent.
      expect(ar[code], isNot('ARABIC-FALLBACK'),
          reason: '$code has no Arabic rendering');
      expect(en[code], isNot('ARABIC-FALLBACK'),
          reason: '$code has no English rendering');
      expect(ar[code]!.trim(), isNotEmpty, reason: '$code is empty in Arabic');
      expect(en[code]!.trim(), isNotEmpty, reason: '$code is empty in English');
      // English must actually be English. `manifest.json` and similar literals
      // are Latin, so this only catches Arabic left behind.
      expect(arabicScript.hasMatch(en[code]!), isFalse,
          reason: '$code still reads Arabic in English: ${en[code]}');
    }
  });

  testWidgets('a code-less exception falls back to its own message',
      (tester) async {
    late String rendered;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('en'),
      home: Builder(builder: (context) {
        rendered = dataPortabilityMessage(
            context, const DataPortabilityException('raw message'));
        return const SizedBox();
      }),
    ));
    // Deliberate: a throw site that has not been given a code yet must still
    // show SOMETHING. Visible-but-Arabic beats silently blank.
    expect(rendered, 'raw message');
  });

  test('every code has an ARB entry in both files', () {
    final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final dpeKeys = ar.keys.where((k) => k.startsWith('dpe')).toSet();
    expect(dpeKeys, isNotEmpty);
    for (final k in dpeKeys) {
      expect(en[k], isA<String>(), reason: '$k is missing from the English ARB');
    }
  });
}
