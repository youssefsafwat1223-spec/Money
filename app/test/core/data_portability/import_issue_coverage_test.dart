import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';

/// `generic_transaction_import.dart` is excluded from the localization sweep at
/// FILE level, because most of its Arabic is genuinely data — CSV type keywords
/// matched against an imported file's cells, and Arabic-Indic digit tables.
///
/// But the same file also raises three user-facing `ImportIssue` messages, and
/// a file-level exclusion cannot see a FOURTH added without a `code:`. It would
/// print Arabic in the English build and never be reported — the exact hole the
/// tool's own comment says file-level exclusions must not leave.
///
/// So the sweep does not guard it; this does. It fails when the two DRIFT,
/// which is a stronger property than "no Arabic is present".
void main() {
  test('every ImportIssue in lib/ carries a code', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      var index = source.indexOf('ImportIssue(');
      while (index != -1) {
        // The constructor call runs to its closing paren; a `code:` anywhere
        // inside it is the thing being asserted. Bounded so a malformed file
        // cannot scan the whole source.
        final end = source.indexOf(');', index);
        final call = source.substring(index, end == -1 ? source.length : end);
        // The class's own constructor DECLARATION also matches
        // `ImportIssue(`; it is identifiable by its `required this.` params
        // and is not a construction site.
        if (call.contains('required this.')) {
          index = source.indexOf('ImportIssue(', index + 1);
          continue;
        }
        if (!call.contains('code:')) {
          final line = '\n'.allMatches(source.substring(0, index)).length + 1;
          offenders.add('${file.path}:$line');
        }
        index = source.indexOf('ImportIssue(', index + 1);
      }
    }
    expect(offenders, isEmpty,
        reason: 'these ImportIssues have no code, so they render raw Arabic '
            'in the English build: ${offenders.join(", ")}');
  });

  test('the renderer handles every ImportIssueCode', () {
    // A code with no arm would not compile (the switch is exhaustive), so what
    // is worth asserting is that the enum has not been emptied or stubbed.
    expect(ImportIssueCode.values, isNotEmpty);
    final renderer =
        File('lib/features/settings/import_issue_messages.dart').readAsStringSync();
    for (final code in ImportIssueCode.values) {
      final name = code.name;
      expect(renderer, contains('ImportIssueCode.$name'),
          reason: '$name has no rendering');
    }
  });
}
