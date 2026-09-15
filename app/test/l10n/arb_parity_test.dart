import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The two ARB files must stay in lockstep.
///
/// A key present in one language and not the other is a missing string at
/// runtime for whoever reads the other language, and `flutter gen-l10n` will
/// happily generate it with a fallback rather than fail. This app declares
/// Arabic only on the App Store (coverage is roughly a tenth of the UI — see
/// V1_LOCALIZATION_MATRIX.md), but the surfaces that ARE localised — Help, the
/// coach marks, every category name — have to be complete in both, because
/// English is reachable in-app from the language setting even though it is not
/// advertised.
void main() {
  Map<String, dynamic> load(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  Set<String> keys(Map<String, dynamic> arb) =>
      arb.keys.where((k) => !k.startsWith('@')).toSet();

  final ar = load('lib/l10n/app_ar.arb');
  final en = load('lib/l10n/app_en.arb');

  test('both languages define exactly the same keys', () {
    final onlyAr = keys(ar).difference(keys(en));
    final onlyEn = keys(en).difference(keys(ar));
    expect(onlyAr, isEmpty, reason: 'missing from app_en.arb: $onlyAr');
    expect(onlyEn, isEmpty, reason: 'missing from app_ar.arb: $onlyEn');
  });

  test('no Arabic script is left sitting in the English file', () {
    final arabic = RegExp(r'[؀-ۿ]');
    final untranslated = <String>[];
    for (final k in keys(en)) {
      final v = en[k];
      if (v is String && arabic.hasMatch(v)) untranslated.add(k);
    }
    expect(untranslated, isEmpty,
        reason: 'these English entries still contain Arabic: $untranslated');
  });

  test('placeholders match between languages', () {
    // A string that interpolates {count} in one language and nothing in the
    // other throws at runtime for exactly one audience.
    final placeholder = RegExp(r'\{(\w+)\}');
    final mismatched = <String>[];
    for (final k in keys(ar)) {
      final a = ar[k];
      final e = en[k];
      if (a is! String || e is! String) continue;
      final pa = placeholder.allMatches(a).map((m) => m.group(1)).toSet();
      final pe = placeholder.allMatches(e).map((m) => m.group(1)).toSet();
      if (pa.length != pe.length || !pa.containsAll(pe)) {
        mismatched.add('$k: ar=$pa en=$pe');
      }
    }
    expect(mismatched, isEmpty,
        reason: 'placeholder sets differ:\n  ${mismatched.join('\n  ')}');
  });

  test('no entry is empty in either language', () {
    final empty = <String>[];
    for (final k in keys(ar)) {
      if ((ar[k] as String?)?.trim().isEmpty ?? true) empty.add('ar:$k');
      if ((en[k] as String?)?.trim().isEmpty ?? true) empty.add('en:$k');
    }
    expect(empty, isEmpty, reason: 'empty strings: $empty');
  });
}
