import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `Currency.arabicLabel(code)` returns Arabic ALWAYS. It is the Arabic half of
/// a pair, and calling it from a widget prints «ريال» to an English reader.
///
/// Three widgets did exactly that — account detail and goal details, on two
/// lines — and produced strings like "Saved 12,750 of 15,000 ريال". None of
/// them had ever been rendered in a test, because every one needs an id in its
/// route and the route walk only covers parameterless routes.
///
/// `Currency.label(context, code)` and `Currency.labelWithCode(context, code)`
/// are the ones a widget wants.
void main() {
  test('no widget calls Currency.arabicLabel directly', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // Its own definition, the doc comment that names it, and the report
      // formatter — which dispatches on an explicit `languageCode` because a
      // PDF has no BuildContext.
      if (file.path.endsWith('core/utils/currency.dart')) continue;
      if (file.path.endsWith('domain/finance/currency_scale.dart')) continue;
      if (file.path.endsWith('composition/report_money_formatter.dart')) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('Currency.arabicLabel')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these print Arabic currency names to an English reader: '
            '${offenders.join(", ")}');
  });

  test('the report formatter dispatches on language, it does not hardcode', () {
    final fmt = File('lib/features/reporting/composition/report_money_formatter.dart')
        .readAsStringSync();
    expect(fmt, contains("languageCode == 'ar'"),
        reason: 'the one permitted caller must still choose by language');
  });
}
