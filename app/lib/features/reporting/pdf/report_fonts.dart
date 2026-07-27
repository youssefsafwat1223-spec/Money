import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// The bundled OFL fonts used to render reports.
///
/// IBM Plex Sans Arabic (SIL OFL 1.1) covers Arabic, Latin and Western digits —
/// its Latin *is* IBM Plex Sans — so one family serves the whole document and
/// avoids relying on `google_fonts` runtime fetching, which a headless renderer
/// cannot use. Fonts are loaded from bundled TTF bytes on the **main isolate**
/// (a background isolate cannot access `rootBundle`) and passed into the pure
/// [ReportPdfRenderer].
class ReportFontSet {
  const ReportFontSet({
    required this.regular,
    required this.medium,
    required this.semiBold,
    required this.bold,
  });

  final pw.Font regular;
  final pw.Font medium;
  final pw.Font semiBold;
  final pw.Font bold;

  List<pw.Font> get fallback => <pw.Font>[regular];
}

/// Raw TTF bytes for the report fonts. Sendable across isolates (unlike the
/// parsed [ReportFontSet]), so isolate rendering builds `pw.Font`s from these.
class ReportFontBytes {
  const ReportFontBytes({
    required this.regular,
    required this.medium,
    required this.semiBold,
    required this.bold,
  });

  final Uint8List regular;
  final Uint8List medium;
  final Uint8List semiBold;
  final Uint8List bold;
}

class ReportFonts {
  const ReportFonts._();

  static const String _dir = 'assets/fonts';
  static ReportFontSet? _cached;
  static ReportFontBytes? _cachedBytes;

  /// Loads (and caches) the report font set from the app bundle.
  static Future<ReportFontSet> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    Future<pw.Font> font(String file) async =>
        pw.Font.ttf(await rootBundle.load('$_dir/$file'));

    final set = ReportFontSet(
      regular: await font('IBMPlexSansArabic-Regular.ttf'),
      medium: await font('IBMPlexSansArabic-Medium.ttf'),
      semiBold: await font('IBMPlexSansArabic-SemiBold.ttf'),
      bold: await font('IBMPlexSansArabic-Bold.ttf'),
    );
    _cached = set;
    return set;
  }

  /// Loads (and caches) the raw TTF bytes, for isolate rendering.
  static Future<ReportFontBytes> loadBytes() async {
    final cached = _cachedBytes;
    if (cached != null) return cached;

    Future<Uint8List> bytes(String file) async {
      final data = await rootBundle.load('$_dir/$file');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final set = ReportFontBytes(
      regular: await bytes('IBMPlexSansArabic-Regular.ttf'),
      medium: await bytes('IBMPlexSansArabic-Medium.ttf'),
      semiBold: await bytes('IBMPlexSansArabic-SemiBold.ttf'),
      bold: await bytes('IBMPlexSansArabic-Bold.ttf'),
    );
    _cachedBytes = set;
    return set;
  }

  /// Builds a parsed [ReportFontSet] from raw [bytes] — call inside a render
  /// isolate (where `rootBundle` is unavailable).
  static ReportFontSet fontSetFromBytes(ReportFontBytes bytes) => ReportFontSet(
        regular: pw.Font.ttf(ByteData.sublistView(bytes.regular)),
        medium: pw.Font.ttf(ByteData.sublistView(bytes.medium)),
        semiBold: pw.Font.ttf(ByteData.sublistView(bytes.semiBold)),
        bold: pw.Font.ttf(ByteData.sublistView(bytes.bold)),
      );

  /// Bundled Qirsh coin PNG bytes for the report brand mark. Returns null if the
  /// asset is missing (the renderer then falls back to a drawn disc).
  static const String _logoAsset = 'assets/qirsh/qirsh_coin.png';
  static Uint8List? _logo;
  static bool _logoLoaded = false;

  static Future<Uint8List?> loadLogoBytes() async {
    if (_logoLoaded) return _logo;
    try {
      final data = await rootBundle.load(_logoAsset);
      _logo = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      _logo = null;
    }
    _logoLoaded = true;
    return _logo;
  }
}
