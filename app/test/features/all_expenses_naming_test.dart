import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';

/// The all-expenses pseudo-category had its display name written in three
/// places, and they disagreed: the budget form's ARB entry said "All spending"
/// while `CategoryView.name` and the report composer said "All expenses". The
/// same row, two names, both reachable by one user in one session — create a
/// whole-ledger budget, then open a transaction.
///
/// Arabic never diverged, because it only ever had one spelling. That is the
/// tell: a second English string appeared each time someone needed the name
/// somewhere without a BuildContext.
///
/// The name now lives on `BudgetEntity`, because `CategoryView` and the PDF
/// composer genuinely have no context to read an ARB from. This asserts the
/// ARB has not drifted away from it again.
void main() {
  test('the ARB agrees with the single source', () {
    final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    expect(ar['bdgAllExpenses'], BudgetEntity.allExpensesNameAr);
    expect(en['bdgAllExpenses'], BudgetEntity.allExpensesNameEn);
  });

  test('nothing spells the name inline any more', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // The declaration itself, and the generated localizations.
      if (file.path.endsWith('domain/entities/budget_entity.dart')) continue;
      // The generated localizations are the ARB compiled; the ARB itself is
      // asserted above.
      if (file.path.startsWith('lib/l10n/')) continue;
      final source = file.readAsStringSync();
      if (source.contains("'All expenses'") ||
          source.contains("'All spending'")) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'these spell the name inline instead of using '
            'BudgetEntity.allExpensesNameEn: ${offenders.join(", ")}');
  });

  test('the two languages are actually different', () {
    expect(BudgetEntity.allExpensesNameEn,
        isNot(BudgetEntity.allExpensesNameAr));
    expect(RegExp(r'[؀-ۿ]').hasMatch(BudgetEntity.allExpensesNameEn), isFalse);
    expect(RegExp(r'[؀-ۿ]').hasMatch(BudgetEntity.allExpensesNameAr), isTrue);
  });
}
