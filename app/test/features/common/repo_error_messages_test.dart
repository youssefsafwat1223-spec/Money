import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/common/repo_error_messages.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// `repoExceptionMessage` (domain, Arabic, for logs and background isolates)
/// and `repoErrorMessage` (UI, localized) are two switches over the same type.
/// Two switches drift: a new exception added to one and forgotten in the other
/// is invisible until a user hits it.
///
/// The analyzer catches a missing arm only if both switches are exhaustive
/// over a sealed type, and it says nothing about whether the two AGREE. This
/// asserts what the analyzer cannot: that every exception the domain can raise
/// renders in both languages, and that the English rendering is actually
/// English.
void main() {
  // Every concrete RepoException. A new subclass added without a line here is
  // the thing worth noticing, so the list is written out rather than derived.
  final all = <RepoException>[
    const NetworkRepoException(),
    const AuthRepoException(),
    const ValidationRepoException('detail'),
    const ForbiddenRepoException(),
    const DuplicateRepoException(),
    const NotFoundRepoException(),
    const ServerRepoException(),
    const UnknownRepoException(),
  ];

  Future<Map<String, String>> renderedIn(
      WidgetTester tester, String lang) async {
    late Map<String, String> out;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(lang),
      home: Builder(builder: (context) {
        out = {
          for (final e in all) e.runtimeType.toString(): repoErrorMessage(context, e),
        };
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('every repository failure renders in both languages',
      (tester) async {
    final arabicScript = RegExp(r'[؀-ۿ]');
    final ar = await renderedIn(tester, 'ar');
    final en = await renderedIn(tester, 'en');

    for (final e in all) {
      final key = e.runtimeType.toString();
      expect(ar[key]!.trim(), isNotEmpty, reason: '$key is empty in Arabic');
      expect(en[key]!.trim(), isNotEmpty, reason: '$key is empty in English');
      expect(arabicScript.hasMatch(en[key]!), isFalse,
          reason: '$key still reads Arabic in English: ${en[key]}');
      expect(ar[key], isNot(en[key]), reason: '$key is identical in both');
    }
  });

  test('the domain fallback covers every case the UI does', () {
    // `repoExceptionMessage` is what a log line and a background isolate get.
    // It must not fall through to a bare type name for anything the UI can
    // show, or the two halves of the pair have drifted.
    for (final e in all) {
      final fallback = repoExceptionMessage(e);
      expect(fallback.trim(), isNotEmpty,
          reason: '${e.runtimeType} has no domain message');
      expect(fallback, isNot(contains('Instance of')),
          reason: '${e.runtimeType} fell through to a toString()');
      expect(RegExp(r'[؀-ۿ]').hasMatch(fallback), isTrue,
          reason: '${e.runtimeType}: the domain fallback is deliberately '
              'Arabic — it is what ships when a call site has no context');
    }
  });
}
