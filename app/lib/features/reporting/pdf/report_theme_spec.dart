import 'package:pdf/pdf.dart';

/// Print-friendly theme for generated reports.
///
/// Mirrors the app's light palette (`AppColors.light`, `app_colors.dart`) and
/// the documented blue→indigo brand accent (`MaliTokens.accentStart/accentEnd`).
/// Values are literal so the PDF never depends on a Flutter `ThemeData` lookup —
/// the renderer runs without a `BuildContext`.
class ReportThemeSpec {
  const ReportThemeSpec();

  // Surfaces & text (AppColors.light). Print pages are white for ink economy;
  // the app canvas (#F6F7FB) is used for subtle fills.
  PdfColor get page => const PdfColor.fromInt(0xFFFFFFFF);
  PdfColor get canvas => const PdfColor.fromInt(0xFFF6F7FB);
  PdfColor get surface => const PdfColor.fromInt(0xFFFFFFFF);
  PdfColor get textPrimary => const PdfColor.fromInt(0xFF111827);
  PdfColor get textSecondary => const PdfColor.fromInt(0xFF4B5563);
  PdfColor get textMuted => const PdfColor.fromInt(0xFF7C879A);
  PdfColor get border => const PdfColor.fromInt(0xFFDDE2EC);
  PdfColor get divider => const PdfColor.fromInt(0xFFE8EBF2);

  // Brand accent (blue → indigo) and deep navy.
  PdfColor get accentStart => const PdfColor.fromInt(0xFF2E6BFF);
  PdfColor get accentEnd => const PdfColor.fromInt(0xFF5B4FE0);
  PdfColor get primary => const PdfColor.fromInt(0xFF021B79);

  // Semantic.
  PdfColor get income => const PdfColor.fromInt(0xFF16A34A);
  PdfColor get expense => const PdfColor.fromInt(0xFFDC2626);
  PdfColor get warning => const PdfColor.fromInt(0xFFD97706);

  // Layout rhythm (mirrors AppSpacing / AppRadius, in PDF points).
  double get pageMargin => 40;
  double get sectionGap => 22;
  double get cardRadius => 14;
}
