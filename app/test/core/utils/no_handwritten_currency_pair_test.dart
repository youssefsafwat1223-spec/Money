import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `Currency.labelWithCode` and `Currency.codeWithLabel` exist because pairing a
/// currency's NAME with its CODE only makes sense in Arabic. «ريال (SAR)» is a
/// familiar word plus an ISO code; in English the label IS the code, so the same
/// pairing renders **"SAR (SAR)"** or **"SAR — SAR"**. Both helpers collapse to
/// a single token when the two halves are equal.
///
/// Helpers do not help a call site that never calls them. `currency_label_with_code_test`
/// proves the collapse rule, and it passed the whole time
/// `account_form_sheet.dart` was writing `'$code — ${Currency.label(context, code)}'`
/// by hand — an English user opening "New account" saw "SAR — SAR" in the
/// currency dropdown. A unit test on a helper cannot see a caller that skips it;
/// only a rendered screen or this scan can.
///
/// That sheet went unseen for a second reason worth keeping in mind: it opens
/// from a button, not a route, so no route walk reached it, and it takes a
/// `WidgetRef`, which the sheet walk declined to synthesise. It was recorded as
/// "covered by widget tests" — and its widget tests never rendered the
/// dropdown.
void main() {
  test('no file pairs a currency code with its label by hand', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // The helpers themselves, and the generated ARB output whose messages are
      // authored per language and so carry no collapse problem.
      if (file.path.endsWith('core/utils/currency.dart')) continue;
      if (file.path.startsWith('lib/l10n/')) continue;

      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (!line.contains('Currency.label(')) continue;
        // The defect shape: the label interpolated into a string that also
        // carries the raw code, in either order and with either separator.
        final pairsWithCode = RegExp(
          r"""(\$\{?code\}?|\$\{?currency\}?|\$\{?[A-Za-z_]*[Cc]urrency\}?)\s*[—\-(]|[—\-(]\s*\$\{Currency\.label""",
        ).hasMatch(line);
        if (pairsWithCode) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these pair a currency code with its own label by hand, which '
            'renders the same token twice in English. Use '
            'Currency.labelWithCode or Currency.codeWithLabel, which collapse '
            'when the halves are equal: ${offenders.join(", ")}');
  });
}
