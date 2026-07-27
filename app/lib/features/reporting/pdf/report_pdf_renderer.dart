import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../composition/report_view_model.dart';
import 'report_fonts.dart';
import 'report_theme_spec.dart';

/// A key/value tile for the Phase-1 probe.
class ProbeTile {
  const ProbeTile(this.label, this.value, {this.color});

  final String label;
  final String value;
  final PdfColor? color;
}

/// Renders report PDFs.
///
/// **Pure**: given fonts + theme + a plain [ReportViewModel] it returns bytes.
/// It never touches Riverpod, repositories, or `BuildContext`, so it can run in
/// a background isolate (fonts are loaded on the main isolate via [ReportFonts]
/// and passed in; the view model is composed on the main isolate too).
class ReportPdfRenderer {
  const ReportPdfRenderer({this.logoBytes});

  /// Optional PNG bytes for the brand mark (the real Qirsh coin). When null the
  /// renderer falls back to a drawn accent disc. Passed as bytes (not a parsed
  /// image) so the renderer stays plain-data / isolate-friendly.
  final Uint8List? logoBytes;

  /// Full core report: cover + summary/cash-flow + comparison/category +
  /// trend/largest. Header, footer, and page numbers on content pages.
  Future<Uint8List> render({
    required ReportViewModel model,
    required ReportFontSet fonts,
    required ReportThemeSpec theme,
  }) async {
    final doc = pw.Document();
    for (final page in _buildPages(model, fonts, theme)) {
      doc.addPage(page);
    }
    return doc.save();
  }

  List<pw.Page> _buildPages(
      ReportViewModel model, ReportFontSet fonts, ReportThemeSpec theme) {
    final td = model.rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;
    final base = pw.TextStyle(
      font: fonts.regular,
      fontFallback: fonts.fallback,
      color: theme.textPrimary,
    );
    return <pw.Page>[
      _coverPage(model, fonts, theme, td, base),
      _summaryPage(model, fonts, theme, td, base),
      _comparisonCategoryPage(model, fonts, theme, td, base),
      _trendLargestPage(model, fonts, theme, td, base),
      _budgetsBillsPage(model, fonts, theme, td, base),
      _goalsObservationsPage(model, fonts, theme, td, base),
      if (model.appendix.isNotEmpty)
        _appendixPage(model, fonts, theme, td, base),
    ];
  }

  /// Renders a single page to its own PDF. Test-only: lets a test rasterize and
  /// inspect one page at a time (no multi-page rasterizer needed).
  Future<Uint8List> renderSinglePage({
    required ReportViewModel model,
    required ReportFontSet fonts,
    required ReportThemeSpec theme,
    required int index,
  }) async {
    final doc = pw.Document();
    doc.addPage(_buildPages(model, fonts, theme)[index]);
    return doc.save();
  }

  // ────────────────────────── cover ──────────────────────────

  pw.Page _coverPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    final c = m.cover;
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 62, 56, 40),
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
      build: (context) => pw.Directionality(
        textDirection: td,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: <pw.Widget>[
            _wordmark(m, fonts, theme, base, large: true),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: <pw.Widget>[
                pw.Text(c.title,
                    style: base.copyWith(
                        font: fonts.bold, fontSize: 40, color: theme.textPrimary)),
                pw.SizedBox(height: 18),
                _accentBar(theme),
                pw.SizedBox(height: 22),
                pw.Text('${c.periodLabel}  ·  ${c.scopeLabel}',
                    style: base.copyWith(fontSize: 14, color: theme.textSecondary)),
              ],
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: <pw.Widget>[
                pw.Text(
                  '${m.strings.currencyWord}: ${c.currencyLabel}  ·  ${c.languageLabel}',
                  style: base.copyWith(fontSize: 11, color: theme.textMuted),
                ),
                pw.SizedBox(height: 4),
                pw.Text('${m.strings.generatedLabel}: ${c.generatedLabel}',
                    style: base.copyWith(fontSize: 11, color: theme.textMuted)),
                pw.SizedBox(height: 14),
                pw.Divider(color: theme.divider, thickness: 0.7, height: 8),
                pw.SizedBox(height: 6),
                pw.Text(m.strings.generatedOnDevice,
                    textAlign: pw.TextAlign.center,
                    style: base.copyWith(fontSize: 9, color: theme.textMuted)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ────────────────────────── content pages ──────────────────────────

  pw.Page _summaryPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    return _contentPage(
      m, fonts, theme, td, base,
      title: m.strings.executiveSummary,
      body: <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.executiveSummary),
        pw.SizedBox(height: 10),
        pw.Row(
          children: <pw.Widget>[
            for (final tile in m.summary.tiles)
              pw.Expanded(
                child: _tile(
                  theme,
                  base,
                  fonts,
                  ProbeTile(tile.label, tile.value,
                      color: tile.colorArgb == null
                          ? null
                          : PdfColor.fromInt(tile.colorArgb!)),
                ),
              ),
          ],
        ),
        pw.SizedBox(height: 12),
        _verdict(theme, base, fonts, m.summary.verdict),
        pw.SizedBox(height: theme.sectionGap),
        _sectionTitle(theme, base, fonts, m.strings.cashFlow),
        pw.SizedBox(height: 10),
        for (final row in m.cashFlow) ...<pw.Widget>[
          _cashFlowCard(theme, base, fonts, m, row),
          pw.SizedBox(height: 8),
        ],
      ],
    );
  }

  pw.Page _comparisonCategoryPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    return _contentPage(
      m, fonts, theme, td, base,
      title: m.strings.comparison,
      body: <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.comparison),
        pw.SizedBox(height: 8),
        _comparisonTable(theme, base, fonts, m),
        pw.SizedBox(height: theme.sectionGap),
        _sectionTitle(theme, base, fonts, m.strings.spendingByCategory,
            subtitle: '${m.category.centerLabel} ${m.category.centerValue}'),
        pw.SizedBox(height: 12),
        _categorySection(theme, base, fonts, m),
      ],
    );
  }

  pw.Page _trendLargestPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    return _contentPage(
      m, fonts, theme, td, base,
      title: m.strings.dailyTrend,
      body: <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.dailyTrend,
            subtitle: m.trend.avgLabel),
        pw.SizedBox(height: 12),
        _barChart(theme, base, fonts, m),
        pw.SizedBox(height: theme.sectionGap),
        _sectionTitle(theme, base, fonts, m.strings.largest),
        pw.SizedBox(height: 8),
        for (final row in m.largest) _amountRow(theme, base, fonts, row),
      ],
    );
  }

  pw.Page _budgetsBillsPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    return _contentPage(
      m, fonts, theme, td, base,
      title: m.strings.budgetsTitle,
      body: <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.budgetsTitle),
        pw.SizedBox(height: 8),
        if (m.budgets.isEmpty)
          _emptyLine(theme, base, m.strings.noData)
        else
          for (final b in m.budgets) _budgetBar(theme, base, fonts, b),
        pw.SizedBox(height: theme.sectionGap),
        _sectionTitle(theme, base, fonts, m.strings.billsTitle),
        pw.SizedBox(height: 8),
        if (m.bills.isEmpty)
          _emptyLine(theme, base, m.strings.noData)
        else
          for (final b in m.bills) _billRow(theme, base, fonts, b),
      ],
    );
  }

  pw.Page _goalsObservationsPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    return _contentPage(
      m, fonts, theme, td, base,
      title: m.strings.goalsTitle,
      body: <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.goalsTitle),
        pw.SizedBox(height: 8),
        if (m.goals.isEmpty)
          _emptyLine(theme, base, m.strings.noData)
        else
          for (final g in m.goals) _goalBar(theme, base, fonts, g),
        pw.SizedBox(height: theme.sectionGap),
        _sectionTitle(theme, base, fonts, m.strings.observationsTitle),
        pw.SizedBox(height: 8),
        if (m.insights.isEmpty)
          _emptyLine(theme, base, m.strings.noData)
        else
          for (final i in m.insights) _insightRow(theme, base, i),
      ],
    );
  }

  pw.Page _appendixPage(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextDirection td, pw.TextStyle base) {
    final head = base.copyWith(fontSize: 8.5, color: theme.textMuted);
    pw.Widget cell(String text, pw.TextStyle style) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 6),
          child: pw.Text(text, style: style, maxLines: 1),
        );
    // A MultiPage auto-paginates the whole table across as many pages as needed,
    // repeating the header row; real page numbers come from the PDF context.
    return pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(44, 40, 44, 34),
        textDirection: td,
        theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
      ),
      header: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 14),
        child: _header(m, fonts, theme, base, m.strings.appendixTitle),
      ),
      footer: (context) => _footer(m, theme, base, context),
      build: (context) => <pw.Widget>[
        _sectionTitle(theme, base, fonts, m.strings.appendixTitle),
        pw.SizedBox(height: 8),
        pw.Table(
          columnWidths: const <int, pw.TableColumnWidth>{
            0: pw.FlexColumnWidth(2),
            1: pw.FlexColumnWidth(4),
            2: pw.FlexColumnWidth(3),
            3: pw.FlexColumnWidth(3),
          },
          border: pw.TableBorder(
            bottom: pw.BorderSide(color: theme.divider, width: 0.7),
            horizontalInside: pw.BorderSide(color: theme.divider, width: 0.5),
          ),
          children: <pw.TableRow>[
            pw.TableRow(repeat: true, children: <pw.Widget>[
              cell(m.strings.apxDate, head),
              cell(m.strings.apxMerchant, head),
              cell(m.strings.apxCategory, head),
              cell(m.strings.apxAmount, head),
            ]),
            for (final r in m.appendix)
              pw.TableRow(children: <pw.Widget>[
                cell(r.date,
                    base.copyWith(fontSize: 9.5, color: theme.textSecondary)),
                cell(r.merchant, base.copyWith(fontSize: 9.5)),
                cell(r.category,
                    base.copyWith(fontSize: 9.5, color: theme.textMuted)),
                cell(
                    r.amount,
                    base.copyWith(
                        font: fonts.semiBold,
                        fontSize: 9.5,
                        color: r.isDebit ? theme.expense : theme.income)),
              ]),
          ],
        ),
      ],
    );
  }

  pw.Page _contentPage(
    ReportViewModel m,
    ReportFontSet fonts,
    ReportThemeSpec theme,
    pw.TextDirection td,
    pw.TextStyle base, {
    required String title,
    required List<pw.Widget> body,
  }) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(44, 40, 44, 34),
      theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
      build: (context) => pw.Directionality(
        textDirection: td,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: <pw.Widget>[
            _header(m, fonts, theme, base, title),
            pw.SizedBox(height: 18),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: body,
              ),
            ),
            _footer(m, theme, base, context),
          ],
        ),
      ),
    );
  }

  // ────────────────────────── shared components ──────────────────────────

  String _brand(bool rtl) => rtl ? 'قرش' : 'Qirsh';

  pw.Widget _wordmark(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextStyle base,
      {bool large = false}) {
    final size = large ? 48.0 : 22.0;
    final font = large ? 28.0 : 15.0;
    final bytes = logoBytes;
    final pw.Widget mark = bytes != null
        ? pw.Image(pw.MemoryImage(bytes),
            width: size, height: size, fit: pw.BoxFit.contain)
        : pw.Container(
            width: size,
            height: size,
            decoration: pw.BoxDecoration(
              shape: pw.BoxShape.circle,
              gradient: pw.LinearGradient(
                colors: <PdfColor>[theme.accentStart, theme.accentEnd],
              ),
            ),
          );
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: <pw.Widget>[
        mark,
        pw.SizedBox(width: large ? 12 : 8),
        pw.Text(_brand(m.rtl),
            style: base.copyWith(
                font: fonts.bold, fontSize: font, color: theme.primary)),
      ],
    );
  }

  pw.Widget _accentBar(ReportThemeSpec theme) => pw.Container(
        width: 92,
        height: 6,
        decoration: pw.BoxDecoration(
          gradient: pw.LinearGradient(
            colors: <PdfColor>[theme.accentStart, theme.accentEnd],
          ),
          borderRadius: pw.BorderRadius.circular(3),
        ),
      );

  pw.Widget _header(ReportViewModel m, ReportFontSet fonts,
      ReportThemeSpec theme, pw.TextStyle base, String title) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: <pw.Widget>[
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: <pw.Widget>[
            _wordmark(m, fonts, theme, base),
            pw.Text('$title · ${m.periodLabel}',
                style: base.copyWith(fontSize: 10, color: theme.textMuted)),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: theme.divider, thickness: 0.7, height: 1),
      ],
    );
  }

  pw.Widget _footer(ReportViewModel m, ReportThemeSpec theme, pw.TextStyle base,
      pw.Context context) {
    final style = base.copyWith(fontSize: 9, color: theme.textMuted);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: <pw.Widget>[
        pw.Divider(color: theme.divider, thickness: 0.7, height: 1),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: <pw.Widget>[
            pw.Text('${_brand(m.rtl)} · ${m.strings.reportTitle}', style: style),
            pw.Text(m.periodLabel, style: style),
            pw.Text(
                '${m.strings.page} ${context.pageNumber} '
                '${m.strings.ofWord} ${context.pagesCount}',
                style: style),
          ],
        ),
      ],
    );
  }

  pw.Widget _sectionTitle(
      ReportThemeSpec theme, pw.TextStyle base, ReportFontSet fonts, String title,
      {String? subtitle}) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: <pw.Widget>[
        pw.Container(
          width: 4,
          height: 15,
          decoration: pw.BoxDecoration(
            gradient: pw.LinearGradient(
              begin: pw.Alignment.topCenter,
              end: pw.Alignment.bottomCenter,
              colors: <PdfColor>[theme.accentStart, theme.accentEnd],
            ),
            borderRadius: pw.BorderRadius.circular(2),
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Text(title,
            style: base.copyWith(
                font: fonts.semiBold, fontSize: 13, color: theme.textPrimary)),
        if (subtitle != null) ...<pw.Widget>[
          pw.Spacer(),
          pw.Text(subtitle,
              style: base.copyWith(fontSize: 9.5, color: theme.textMuted)),
        ],
      ],
    );
  }

  pw.Widget _tile(ReportThemeSpec theme, pw.TextStyle base, ReportFontSet fonts,
      ProbeTile tile) {
    return pw.Container(
      margin: const pw.EdgeInsets.symmetric(horizontal: 4),
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: theme.surface,
        border: pw.Border.all(color: theme.border),
        borderRadius: pw.BorderRadius.circular(theme.cardRadius),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(tile.label,
              style: base.copyWith(fontSize: 9, color: theme.textMuted)),
          pw.SizedBox(height: 5),
          // Keep the page direction so a trailing Arabic currency word is not
          // reversed; bidi lays the numeric run out LTR within an RTL line.
          pw.Text(tile.value,
              style: base.copyWith(
                  font: fonts.semiBold,
                  fontSize: 15,
                  color: tile.color ?? theme.textPrimary)),
        ],
      ),
    );
  }

  pw.Widget _verdict(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, String verdict) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFFEFF3FF),
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFDCE4FF)),
        borderRadius: pw.BorderRadius.circular(12),
      ),
      child: pw.Text(verdict,
          style: base.copyWith(fontSize: 11.5, color: theme.primary, lineSpacing: 2)),
    );
  }

  pw.Widget _cashFlowCard(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, ReportViewModel m, CashFlowRowVM row) {
    pw.Widget kv(String k, String v, {PdfColor? color}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text(k, style: base.copyWith(fontSize: 11, color: theme.textSecondary)),
              pw.Text(v,
                  style: base.copyWith(
                      font: fonts.semiBold, fontSize: 11, color: color ?? theme.textPrimary)),
            ],
          ),
        );
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: theme.border),
        borderRadius: pw.BorderRadius.circular(theme.cardRadius),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: <pw.Widget>[
          if (m.cashFlow.length > 1)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Text(row.currency,
                  style: base.copyWith(font: fonts.semiBold, fontSize: 11)),
            ),
          kv(m.strings.income, row.income, color: theme.income),
          kv(m.strings.expense, row.expense, color: theme.expense),
          kv(m.strings.net, row.net),
          kv(m.strings.savingsRate, row.savingsRate, color: theme.accentStart),
        ],
      ),
    );
  }

  pw.Widget _comparisonTable(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, ReportViewModel m) {
    final head = base.copyWith(fontSize: 9, color: theme.textMuted);
    pw.Widget cell(String text, pw.TextStyle style) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: pw.Text(text, style: style),
        );
    PdfColor kindColor(DeltaKind k) => switch (k) {
          DeltaKind.up => theme.income,
          DeltaKind.down => theme.expense,
          DeltaKind.neutral => theme.textMuted,
        };
    return pw.Table(
      columnWidths: const <int, pw.TableColumnWidth>{
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(3),
        2: pw.FlexColumnWidth(3),
        3: pw.FlexColumnWidth(2.4),
      },
      border: pw.TableBorder(
        bottom: pw.BorderSide(color: theme.divider, width: 0.7),
        horizontalInside: pw.BorderSide(color: theme.divider, width: 0.7),
      ),
      children: <pw.TableRow>[
        pw.TableRow(children: <pw.Widget>[
          cell(m.strings.metric, head),
          cell(m.strings.thisPeriod, head),
          cell(m.strings.previous, head),
          cell(m.strings.change, head),
        ]),
        for (final row in m.comparison)
          pw.TableRow(children: <pw.Widget>[
            cell(row.metric, base.copyWith(fontSize: 10.5, color: theme.textSecondary)),
            cell(row.thisValue,
                base.copyWith(font: fonts.semiBold, fontSize: 10.5)),
            cell(row.previousValue, base.copyWith(fontSize: 10.5, color: theme.textSecondary)),
            cell(row.delta,
                base.copyWith(
                    font: fonts.semiBold, fontSize: 10, color: kindColor(row.kind))),
          ]),
      ],
    );
  }

  pw.Widget _categorySection(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, ReportViewModel m) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: <pw.Widget>[
        pw.SizedBox(
          width: 150,
          height: 150,
          child: pw.Stack(
            alignment: pw.Alignment.center,
            children: <pw.Widget>[
              pw.CustomPaint(
                size: const PdfPoint(150, 150),
                painter: (PdfGraphics canvas, PdfPoint size) =>
                    _paintDonut(canvas, size, m.category.slices, theme),
              ),
              pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                children: <pw.Widget>[
                  pw.Text(m.category.centerLabel,
                      style: base.copyWith(fontSize: 8, color: theme.textMuted)),
                  pw.SizedBox(height: 2),
                  pw.Text(m.category.centerValue,
                      style: base.copyWith(font: fonts.semiBold, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 18),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              for (final row in m.category.rows)
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3.5),
                  child: pw.Row(
                    children: <pw.Widget>[
                      pw.Container(
                        width: 10,
                        height: 10,
                        margin: const pw.EdgeInsets.only(right: 8, left: 8),
                        decoration: pw.BoxDecoration(
                          color: PdfColor.fromInt(row.colorArgb),
                          borderRadius: pw.BorderRadius.circular(3),
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Text(row.label,
                            style: base.copyWith(fontSize: 10.5)),
                      ),
                      pw.Text(row.value,
                          style: base.copyWith(
                              font: fonts.semiBold, fontSize: 10.5)),
                      pw.SizedBox(width: 10),
                      pw.SizedBox(
                        width: 34,
                        child: pw.Text(row.percent,
                            textAlign: pw.TextAlign.right,
                            style:
                                base.copyWith(fontSize: 9.5, color: theme.textMuted)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _paintDonut(PdfGraphics canvas, PdfPoint size, List<DonutSliceVM> slices,
      ReportThemeSpec theme) {
    final total = slices.fold<double>(0, (s, x) => s + x.value);
    if (total <= 0) return;
    final cx = size.x / 2;
    final cy = size.y / 2;
    final r = math.min(cx, cy);
    var start = math.pi / 2; // start at top, sweep clockwise
    for (final slice in slices) {
      if (slice.value <= 0) continue;
      final sweep = (slice.value / total) * 2 * math.pi;
      final steps = math.max(2, (sweep / (math.pi / 90)).ceil());
      canvas.setFillColor(PdfColor.fromInt(slice.colorArgb));
      canvas.moveTo(cx, cy);
      for (var i = 0; i <= steps; i++) {
        final a = start - sweep * (i / steps);
        canvas.lineTo(cx + r * math.cos(a), cy + r * math.sin(a));
      }
      canvas.fillPath();
      start -= sweep;
    }
    canvas.setFillColor(theme.surface);
    canvas.drawEllipse(cx, cy, r * 0.58, r * 0.58);
    canvas.fillPath();
  }

  pw.Widget _barChart(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, ReportViewModel m) {
    final trend = m.trend;
    const height = 130.0;
    final max = trend.maxValue <= 0 ? 1.0 : trend.maxValue;
    final avgY = (trend.avg / max).clamp(0.0, 1.0) * height;
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: theme.border),
        borderRadius: pw.BorderRadius.circular(theme.cardRadius),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: <pw.Widget>[
          pw.SizedBox(
            height: height,
            child: pw.Stack(
              children: <pw.Widget>[
                pw.Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: <pw.Widget>[
                      for (var i = 0; i < trend.bars.length; i++)
                        pw.Expanded(
                          child: pw.Container(
                            margin: const pw.EdgeInsets.symmetric(horizontal: 0.7),
                            height: (trend.bars[i] / max).clamp(0.0, 1.0) * height,
                            decoration: pw.BoxDecoration(
                              color: i == trend.hotIndex
                                  ? theme.accentEnd
                                  : theme.accentStart,
                              borderRadius: pw.BorderRadius.circular(1.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                pw.Positioned(
                  left: 0,
                  right: 0,
                  bottom: avgY,
                  child: pw.Container(height: 0.8, color: theme.textMuted),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              for (final label in trend.xLabels)
                pw.Text(label,
                    style: base.copyWith(fontSize: 8.5, color: theme.textMuted)),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _amountRow(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, AmountRowVM row) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: theme.divider, width: 0.7)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text(row.title, style: base.copyWith(fontSize: 11)),
                if (row.subtitle.isNotEmpty)
                  pw.Text(row.subtitle,
                      style: base.copyWith(fontSize: 9, color: theme.textMuted)),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Text(row.value,
              style: base.copyWith(
                  font: fonts.semiBold,
                  fontSize: 11,
                  color: row.colorArgb == null
                      ? theme.textPrimary
                      : PdfColor.fromInt(row.colorArgb!))),
        ],
      ),
    );
  }

  pw.Widget _budgetBar(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, BudgetBarVM vm) {
    final w = (vm.ratio * 100).round().clamp(0, 100);
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: theme.divider, width: 0.7)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: <pw.Widget>[
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text(vm.label,
                  style: base.copyWith(font: fonts.semiBold, fontSize: 11)),
              pw.Text(vm.status,
                  style: base.copyWith(
                      font: fonts.semiBold,
                      fontSize: 9,
                      color: PdfColor.fromInt(vm.colorArgb))),
            ],
          ),
          pw.SizedBox(height: 5),
          pw.Container(
            height: 8,
            decoration: pw.BoxDecoration(
              color: const PdfColor.fromInt(0xFFECEFF6),
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Row(children: <pw.Widget>[
              if (w > 0)
                pw.Expanded(
                  flex: w,
                  child: pw.Container(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromInt(vm.colorArgb),
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                  ),
                ),
              if (w < 100) pw.Expanded(flex: 100 - w, child: pw.SizedBox()),
            ]),
          ),
          pw.SizedBox(height: 3),
          pw.Text(vm.amounts,
              style: base.copyWith(fontSize: 9, color: theme.textMuted)),
        ],
      ),
    );
  }

  pw.Widget _billRow(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, BillRowVM vm) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: theme.divider, width: 0.7)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.Container(
            width: 6,
            height: 6,
            margin: const pw.EdgeInsets.only(right: 8, left: 8),
            decoration: pw.BoxDecoration(
              color: vm.isSubscription ? theme.accentStart : theme.textMuted,
              shape: pw.BoxShape.circle,
            ),
          ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text(vm.name, style: base.copyWith(fontSize: 11)),
                if (vm.due.isNotEmpty)
                  pw.Text(vm.due,
                      style: base.copyWith(fontSize: 9, color: theme.textMuted)),
              ],
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Text(vm.amount,
              style: base.copyWith(font: fonts.semiBold, fontSize: 11)),
        ],
      ),
    );
  }

  pw.Widget _goalBar(ReportThemeSpec theme, pw.TextStyle base,
      ReportFontSet fonts, GoalBarVM vm) {
    final w = (vm.progress * 100).round().clamp(0, 100);
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: theme.divider, width: 0.7)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: <pw.Widget>[
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text(vm.name,
                  style: base.copyWith(font: fonts.semiBold, fontSize: 11)),
              pw.Text('${vm.amounts} · ${vm.percent}',
                  style: base.copyWith(fontSize: 9.5, color: theme.textMuted)),
            ],
          ),
          pw.SizedBox(height: 5),
          pw.Container(
            height: 9,
            decoration: pw.BoxDecoration(
              color: const PdfColor.fromInt(0xFFECEFF6),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(children: <pw.Widget>[
              if (w > 0)
                pw.Expanded(
                  flex: w,
                  child: pw.Container(
                    decoration: pw.BoxDecoration(
                      gradient: pw.LinearGradient(
                        colors: <PdfColor>[theme.accentStart, theme.accentEnd],
                      ),
                      borderRadius: pw.BorderRadius.circular(5),
                    ),
                  ),
                ),
              if (w < 100) pw.Expanded(flex: 100 - w, child: pw.SizedBox()),
            ]),
          ),
          if (vm.meta.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 4),
            pw.Text(vm.meta,
                style: base.copyWith(fontSize: 9, color: theme.textMuted)),
          ],
        ],
      ),
    );
  }

  pw.Widget _insightRow(
      ReportThemeSpec theme, pw.TextStyle base, InsightRowVM vm) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 6),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: theme.divider, width: 0.7)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Container(
            width: 8,
            height: 8,
            margin: const pw.EdgeInsets.only(top: 4, right: 8, left: 8),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromInt(vm.colorArgb),
              shape: pw.BoxShape.circle,
            ),
          ),
          pw.Expanded(
            child: pw.Text(vm.text,
                style: base.copyWith(fontSize: 11, lineSpacing: 1.5)),
          ),
        ],
      ),
    );
  }

  pw.Widget _emptyLine(ReportThemeSpec theme, pw.TextStyle base, String text) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        child: pw.Text(text,
            style: base.copyWith(fontSize: 10.5, color: theme.textMuted)),
      );

  // ────────────────────────── Phase-1 probe (kept) ──────────────────────────

  /// One page exercising Arabic shaping, mixed Arabic/Latin, tabular digits and
  /// a trailing currency word — the Phase-1 validation page.
  Future<Uint8List> renderProbe({
    required ReportFontSet fonts,
    required ReportThemeSpec theme,
    required bool rtl,
    required String title,
    required String subtitle,
    required List<ProbeTile> tiles,
    required String paragraph,
  }) async {
    final doc = pw.Document();
    final base = pw.TextStyle(
      font: fonts.regular,
      fontFallback: fonts.fallback,
      color: theme.textPrimary,
    );
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(theme.pageMargin),
        theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold),
        build: (context) => pw.Directionality(
          textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.Text(title,
                  style: base.copyWith(
                      font: fonts.bold, fontSize: 30, color: theme.primary)),
              pw.SizedBox(height: 8),
              _accentBar(theme),
              pw.SizedBox(height: 10),
              pw.Text(subtitle,
                  style: base.copyWith(fontSize: 13, color: theme.textSecondary)),
              pw.SizedBox(height: theme.sectionGap),
              pw.Row(children: <pw.Widget>[
                for (final tile in tiles) pw.Expanded(child: _tile(theme, base, fonts, tile)),
              ]),
              pw.SizedBox(height: theme.sectionGap),
              pw.Text(paragraph,
                  style: base.copyWith(
                      fontSize: 12, color: theme.textSecondary, lineSpacing: 3)),
            ],
          ),
        ),
      ),
    );
    return doc.save();
  }
}
