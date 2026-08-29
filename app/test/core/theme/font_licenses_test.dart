import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/font_licenses.dart';

/// Release prep — the bundled fonts carry their licences, and can't stop doing so.
///
/// `google_fonts` was removed so nothing is fetched at runtime; every family is
/// a `.ttf` inside the app binary. Shipping a font is redistributing it, and the
/// SIL Open Font License requires the copyright notice and licence text to come
/// with it. This asserts that obligation structurally rather than trusting that
/// whoever adds the next family remembers.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// Families declared under `flutter: fonts:` in pubspec.yaml.
  List<String> declaredFamilies() {
    final fontsBlock = pubspec.substring(pubspec.indexOf('\n  fonts:'));
    return RegExp(r'^    - family:\s*(.+)$', multiLine: true)
        .allMatches(fontsBlock)
        .map((m) => m.group(1)!.trim())
        .toList();
  }

  test('every bundled family has a licence entry', () {
    // The guard that matters: adding a font without its licence fails here,
    // rather than shipping an unattributed typeface.
    final declared = declaredFamilies();
    expect(declared, isNotEmpty, reason: 'no families parsed from pubspec');

    for (final family in declared) {
      final key = kBundledFontLicenses.keys.firstWhere(
        (k) => k.replaceAll(' ', '').toLowerCase() ==
            family.replaceAll(' ', '').toLowerCase(),
        orElse: () => '',
      );
      expect(key, isNotEmpty,
          reason: '«$family» is bundled but has no licence in '
              'kBundledFontLicenses — shipping the .ttf without its OFL notice '
              'is a redistribution without attribution');
    }
  });

  test('every licence file exists and is declared as an asset', () {
    for (final entry in kBundledFontLicenses.entries) {
      final file = File(entry.value);
      expect(file.existsSync(), isTrue, reason: '${entry.value} is missing');
      // A file that exists on disk but is not in the asset bundle would load
      // fine in a test and fail on device — the worst of both.
      expect(pubspec, contains('assets/fonts/'),
          reason: 'assets/fonts/ must be declared for the licence to ship');
    }
  });

  group('the licence texts are real OFL 1.1, not placeholders', () {
    for (final entry in kBundledFontLicenses.entries) {
      test(entry.key, () {
        final text = File(entry.value).readAsStringSync();
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(text, contains('PERMISSION & CONDITIONS'));
        expect(text, contains('TERMINATION'));
        expect(text.split('\n').length, greaterThan(80),
            reason: 'the full licence body, not a summary line');
        expect(text.trimLeft().startsWith('Copyright'), isTrue,
            reason: 'OFL requires the copyright notice to accompany the text');
      });
    }
  });

  group('IBM Plex — assembled from authoritative local sources', () {
    final ibm =
        File('assets/fonts/IBMPlexSansArabic-OFL.txt').readAsStringSync();

    test('the copyright line is IBM own, from the shipped .ttf name table', () {
      // nameID 0 of every IBMPlexSansArabic-*.ttf in assets/fonts/. Read out of
      // the binary IBM shipped rather than transcribed from a web page.
      expect(ibm, startsWith('Copyright 2019 IBM Corp. All rights reserved.'));
    });

    test('the FAQ URL matches the one the font itself declares', () {
      // IBM's nameID 14 is http://scripts.sil.org/OFL. Two OFL copies exist in
      // this repo and they differ ONLY on this URL, so the font's own metadata
      // decides which variant is correct here.
      expect(ibm, contains('http://scripts.sil.org/OFL'));
    });

    test('the licence body is byte-identical to the in-repo canonical OFL', () {
      // Sourcing check, not a formatting one: the body was copied from a
      // licence already in the tree, itself verified identical to a second
      // independently-sourced copy. If these ever diverge, the IBM file was
      // edited by hand — which is exactly what must not happen to licence text.
      String body(String path) =>
          File(path).readAsStringSync().split('\n').skip(2).join('\n');
      expect(body('assets/fonts/IBMPlexSansArabic-OFL.txt'),
          body('assets/fonts/Vazirmatn-OFL.txt'));
    });
  });
}
