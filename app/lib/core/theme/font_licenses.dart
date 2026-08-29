import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Registers the bundled fonts' OFL licences with Flutter's licence registry.
///
/// ## Why this exists
///
/// `google_fonts` was removed in B2-D so the app never fetches typography over
/// the network — every family is a `.ttf` shipped inside the bundle. That moves
/// an obligation onto us: the SIL Open Font License requires the copyright
/// notice and licence text to travel with any redistribution of the font, and
/// an app binary containing the `.ttf` is a redistribution.
///
/// The `.txt` files sit in `assets/fonts/`, which `pubspec.yaml` declares, so
/// they already ship. What they were not was *reachable* — Flutter's
/// `showLicensePage` enumerates package licences from the build system and
/// knows nothing about asset files, so the licence for the typeface the user is
/// looking at appeared nowhere in the app.
///
/// ## Sourcing
///
/// Every file here came from the font project itself, never from a search:
///
/// * `Alexandria-OFL.txt` and `Vazirmatn-OFL.txt` ship with those projects.
/// * `IBMPlexSansArabic-OFL.txt` was assembled from two authoritative local
///   sources rather than downloaded — the copyright line is IBM's own
///   `name` table entry (nameID 0: *"Copyright 2019 IBM Corp. All rights
///   reserved."*) read out of the shipped `.ttf`, and the licence body is the
///   canonical OFL 1.1 text already in this repository, verified byte-identical
///   between two independently-sourced font projects. IBM's `nameID 14`
///   declares `http://scripts.sil.org/OFL`, which is why the Vazirmatn variant
///   of the FAQ URL is the one used.
///
/// ## Failure posture
///
/// A missing or unreadable licence asset must never take down app startup: the
/// user losing their finance app because a text file failed to load would be a
/// far worse outcome than an incomplete licence page. Each file is loaded
/// independently and a failure is reported in debug and skipped in release.
/// The `licenses_bundled_test` asserts every bundled family has a file, so a
/// silent gap is caught at build time rather than at runtime.
const Map<String, String> kBundledFontLicenses = {
  'IBM Plex Sans Arabic': 'assets/fonts/IBMPlexSansArabic-OFL.txt',
  'Vazirmatn': 'assets/fonts/Vazirmatn-OFL.txt',
  'Alexandria': 'assets/fonts/Alexandria-OFL.txt',
};

/// Adds one licence entry per bundled family. Call once, before `runApp`.
void registerBundledFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in kBundledFontLicenses.entries) {
      final String text;
      try {
        text = await rootBundle.loadString(entry.value);
      } catch (error) {
        assert(() {
          debugPrint('[licenses] ${entry.key}: ${entry.value} unreadable — '
              '$error');
          return true;
        }());
        continue;
      }
      yield LicenseEntryWithLineBreaks(<String>[entry.key], text);
    }
  });
}
