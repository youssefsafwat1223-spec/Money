import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// NO SURFACE MAY FORCE ITS OWN TEXT DIRECTION.
///
/// 31 widgets across 19 files wrapped their content in
/// `Directionality(textDirection: TextDirection.rtl, …)` — Arabic-first
/// leftovers. Under `en` they produced mirrored layouts with English text:
/// the goal form rendered its title right-aligned, its close button on the
/// left, and its hint as ".The suggested amount appears once you pick a date"
/// — the full stop at the START of the sentence, which is what an LTR string
/// laid out in an RTL paragraph looks like.
///
/// ## Why the existing direction assertion did not catch it
///
/// `bilingual_walk_test` asserts `Directionality.of()` on every route in both
/// languages, and passed. It reads the direction at the route's FIRST
/// `Scaffold` — and every one of these wrappers sits BELOW that, around a
/// body, a sheet or a section. The assertion was true at the node it measured
/// and false three widgets down.
///
/// A rendered screenshot is what found it. This is what keeps it found.
void main() {
  test('no widget hardcodes TextDirection.rtl', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // The PDF renderer composes a document, not a widget tree; its direction
      // comes from the report model and is already locale-derived.
      if (file.path.contains('report_pdf_renderer.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // `textDirection: TextDirection.rtl` ASSIGNS a direction.
        // `== TextDirection.rtl` and `TextDirection.rtl =>` READ one, which is
        // how a widget adapts to the direction rather than dictating it.
        if (line.contains('textDirection: TextDirection.rtl')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these force RTL regardless of locale, so an English reader '
            'gets a mirrored layout: ${offenders.join(", ")}');
  });

  test('the ones that remain READ the direction, they do not set it', () {
    // Guard against the fix being undone by re-introducing the constant under
    // a different spelling.
    final chevron =
        File('lib/core/theme/widgets/directional_chevron.dart').readAsStringSync();
    expect(chevron, contains('TextDirection.rtl =>'),
        reason: 'the chevron must still switch ON direction — it is the one '
            'widget whose whole job is mirroring');
  });
}
