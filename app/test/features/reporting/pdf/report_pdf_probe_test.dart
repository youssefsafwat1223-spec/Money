import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/reporting/pdf/report_fonts.dart';
import 'package:money_companion/features/reporting/pdf/report_pdf_renderer.dart';
import 'package:money_companion/features/reporting/pdf/report_theme_spec.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  const theme = ReportThemeSpec();
  const renderer = ReportPdfRenderer();

  pw.Font fontFrom(String file) {
    final bytes = File('assets/fonts/$file').readAsBytesSync();
    return pw.Font.ttf(ByteData.sublistView(bytes));
  }

  ReportFontSet loadFonts() => ReportFontSet(
        regular: fontFrom('IBMPlexSansArabic-Regular.ttf'),
        medium: fontFrom('IBMPlexSansArabic-Medium.ttf'),
        semiBold: fontFrom('IBMPlexSansArabic-SemiBold.ttf'),
        bold: fontFrom('IBMPlexSansArabic-Bold.ttf'),
      );

  test('renders a valid Arabic (RTL) probe PDF', () async {
    final bytes = await renderer.renderProbe(
      fonts: loadFonts(),
      theme: theme,
      rtl: true,
      title: 'التقرير المالي',
      subtitle: '1 – 31 يوليو 2026 · جميع الحسابات',
      tiles: <ProbeTile>[
        ProbeTile('الدخل', '12,400.00 ريال', color: theme.income),
        ProbeTile('المصروفات', '8,730.00 ريال', color: theme.expense),
        const ProbeTile('الصافي', '+3,670.00 ريال'),
      ],
      paragraph:
          'أنفقت 11.9% أقل من الشهر الماضي وتحسّن معدل ادخارك إلى 30%. أكبر عملية كانت لدى IKEA بمبلغ 1,240.00 ريال في 14 يوليو.',
    );

    expect(bytes.length, greaterThan(2000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    File('build/report_probe_ar.pdf').writeAsBytesSync(bytes);
  });

  test('renders a valid English (LTR) probe PDF', () async {
    final bytes = await renderer.renderProbe(
      fonts: loadFonts(),
      theme: theme,
      rtl: false,
      title: 'Financial Report',
      subtitle: '1 – 31 July 2026 · All accounts',
      tiles: <ProbeTile>[
        ProbeTile('Income', '12,400.00 SAR', color: theme.income),
        ProbeTile('Expenses', '8,730.00 SAR', color: theme.expense),
        const ProbeTile('Net', '+3,670.00 SAR'),
      ],
      paragraph:
          'You spent 11.9% less than last month and improved your savings rate to 30%. '
          'The largest purchase was IKEA at 1,240.00 SAR on 14 July.',
    );

    expect(bytes.length, greaterThan(2000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    File('build/report_probe_en.pdf').writeAsBytesSync(bytes);
  });
}
