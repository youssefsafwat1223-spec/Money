import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/reporting/report_request.dart';
import '../../settings/settings_providers.dart';
import '../providers/report_providers.dart';
import '../services/report_generation_controller.dart';
import '../../common/app_header.dart';
import 'report_preview_screen.dart';
import '../../../core/utils/app_lucide_icons.dart';

enum _PeriodKind { weekly, monthly, yearly, custom }

String _t(bool isAr, String ar, String en) => isAr ? ar : en;

/// Opens the report configuration PAGE and returns the chosen [ReportRequest],
/// or null if the user backs out.
///
/// This is a normal full-screen route (it used to be a modal bottom sheet): the
/// form is long enough that a sheet cramped it against the keyboard. The
/// returned value and every downstream step — coordinator → ad gate →
/// generation → [ReportPreviewScreen] — are unchanged.
Future<ReportRequest?> showReportConfigPage(BuildContext context) {
  return Navigator.of(context).push<ReportRequest>(
    MaterialPageRoute<ReportRequest>(
      builder: (_) => const _ReportConfigPage(),
    ),
  );
}

class _ReportConfigPage extends ConsumerStatefulWidget {
  const _ReportConfigPage();

  @override
  ConsumerState<_ReportConfigPage> createState() => _ReportConfigPageState();
}

class _ReportConfigPageState extends ConsumerState<_ReportConfigPage> {
  _PeriodKind _period = _PeriodKind.monthly;
  DateTimeRange? _customRange;
  bool _allAccounts = true;
  String? _accountId;
  late String _lang;
  bool _details = false;
  bool _merchants = true;
  bool _accounts = true;
  bool _balances = true;
  bool _insights = true;
  bool _privacy = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(userSettingsProvider).valueOrNull;
    _lang = settings?.language == 'en' ? 'en' : 'ar';
    _privacy = settings?.privacyModeEnabled ?? false;
  }

  ReportRequest _buildRequest() {
    final ReportPeriod period = switch (_period) {
      _PeriodKind.weekly => const WeeklyPeriod(),
      _PeriodKind.yearly => const YearlyPeriod(),
      _PeriodKind.custom => CustomPeriod(
          from: DateTime(_customRange!.start.year, _customRange!.start.month,
              _customRange!.start.day),
          to: DateTime(_customRange!.end.year, _customRange!.end.month,
                  _customRange!.end.day)
              .add(const Duration(days: 1)),
        ),
      _PeriodKind.monthly => const MonthlyPeriod(),
    };
    final scope = (_allAccounts || _accountId == null)
        ? const AllAccountsScope()
        : SingleAccountScope(_accountId!);
    return ReportRequest(
      period: period,
      scope: scope,
      languageCode: _lang,
      content: ReportContentOptions(
        includeTransactionDetails: _details,
        includeMerchantNames: _merchants,
        includeAccountNames: _accounts,
        includeBalances: _balances,
        includeInsights: _insights,
      ),
      privacyMode: _privacy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode != 'en';
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <AccountEntity>[];
    final canGenerate = _period != _PeriodKind.custom || _customRange != null;

    return Scaffold(
      appBar: AppHeader(
          title: _t(isAr, 'إنشاء تقرير مالي', 'Create financial report')),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _label(isAr, 'الفترة', 'Period'),
            Wrap(
              spacing: 8,
              children: <Widget>[
                _periodChip(isAr, _PeriodKind.weekly, 'أسبوعي', 'Weekly'),
                _periodChip(isAr, _PeriodKind.monthly, 'شهري', 'Monthly'),
                _periodChip(isAr, _PeriodKind.yearly, 'سنوي', 'Yearly'),
                _periodChip(isAr, _PeriodKind.custom, 'مخصّص', 'Custom'),
              ],
            ),
            if (_period == _PeriodKind.custom)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(AppLucideIcons.calendarRange, size: 18),
                  label: Text(_customRange == null
                      ? _t(isAr, 'اختر المدى', 'Pick a range')
                      : '${_customRange!.start.toString().split(' ').first}'
                          ' → ${_customRange!.end.toString().split(' ').first}'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(now.year - 5),
                      lastDate: now,
                      initialDateRange: _customRange,
                    );
                    if (picked != null) setState(() => _customRange = picked);
                  },
                ),
              ),
            const SizedBox(height: 16),
            _label(isAr, 'الحسابات', 'Accounts'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_t(isAr, 'كل الحسابات', 'All accounts')),
              value: _allAccounts,
              onChanged: (v) => setState(() => _allAccounts = v),
            ),
            if (!_allAccounts && accounts.isNotEmpty)
              DropdownButton<String>(
                isExpanded: true,
                value: _accountId ?? accounts.first.id,
                items: <DropdownMenuItem<String>>[
                  for (final a in accounts)
                    DropdownMenuItem<String>(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setState(() => _accountId = v),
              ),
            const SizedBox(height: 12),
            _label(isAr, 'اللغة', 'Language'),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'ar', label: Text('العربية')),
                ButtonSegment<String>(value: 'en', label: Text('English')),
              ],
              selected: <String>{_lang},
              onSelectionChanged: (s) => setState(() => _lang = s.first),
            ),
            const SizedBox(height: 8),
            _switch(isAr, 'تفاصيل العمليات', 'Transaction details', _details,
                (v) => _details = v),
            _switch(isAr, 'أسماء المتاجر', 'Merchant names', _merchants,
                (v) => _merchants = v),
            _switch(isAr, 'أسماء الحسابات', 'Account names', _accounts,
                (v) => _accounts = v),
            _switch(
                isAr, 'الأرصدة', 'Balances', _balances, (v) => _balances = v),
            _switch(
                isAr, 'الملاحظات', 'Insights', _insights, (v) => _insights = v),
            _switch(isAr, 'وضع الخصوصية (إخفاء المبالغ)',
                'Privacy mode (mask amounts)', _privacy, (v) => _privacy = v),
          ],
        ),
      ),
      // Pinned action so the primary CTA stays reachable on a long form.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(AppLucideIcons.fileText, size: 18),
            label: Text(_t(isAr, 'إنشاء التقرير', 'Generate report')),
            onPressed: canGenerate
                ? () => Navigator.of(context).pop(_buildRequest())
                : null,
          ),
        ),
      ),
    );
  }

  Widget _label(bool isAr, String ar, String en) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(_t(isAr, ar, en),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.outline)),
      );

  Widget _periodChip(bool isAr, _PeriodKind kind, String ar, String en) =>
      ChoiceChip(
        label: Text(_t(isAr, ar, en)),
        selected: _period == kind,
        onSelected: (_) => setState(() => _period = kind),
      );

  Widget _switch(bool isAr, String ar, String en, bool value,
          ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(_t(isAr, ar, en)),
        value: value,
        onChanged: (v) => setState(() => onChanged(v)),
      );
}

/// Runs generation with a progress dialog and, on success, opens the preview.
Future<void> runReportGeneration(
    BuildContext context, WidgetRef ref, ReportRequest request) async {
  final isAr = Localizations.localeOf(context).languageCode != 'en';
  // Best-effort cleanup of stale report temp files from previous sessions.
  unawaited(ref.read(reportFileServiceProvider).sweepStale());
  final controller = ref.read(reportGenerationControllerProvider)..invalidate();
  final cancel = ReportCancelToken();
  final progress = ValueNotifier<ReportProgress>(
      const ReportProgress(ReportStage.collecting, 0.05));

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        _ProgressDialog(progress: progress, cancel: cancel, isAr: isAr),
  );

  try {
    final result = await controller.generate(
      request,
      cancel: cancel,
      onProgress: (p) => progress.value = p,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReportPreviewScreen(
        bytes: result.bytes,
        export: result.export,
        fileService: ref.read(reportFileServiceProvider),
        containsSensitive: !request.privacyMode,
      ),
    ));
  } on ReportGenerationException catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress
    if (e.kind == ReportErrorKind.cancelled) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_errorText(e.kind, isAr))));
  } finally {
    progress.dispose();
  }
}

String _errorText(ReportErrorKind kind, bool isAr) => switch (kind) {
      ReportErrorKind.noData =>
        _t(isAr, 'لا توجد بيانات في هذه الفترة', 'No data for this period'),
      ReportErrorKind.fontLoadFailed =>
        _t(isAr, 'تعذّر تحميل الخطوط', 'Could not load fonts'),
      ReportErrorKind.renderFailed =>
        _t(isAr, 'تعذّر إنشاء ملف PDF', 'Could not render the PDF'),
      ReportErrorKind.writeFailed =>
        _t(isAr, 'تعذّر حفظ الملف', 'Could not save the file'),
      ReportErrorKind.cancelled => _t(isAr, 'أُلغي', 'Cancelled'),
      ReportErrorKind.unknown =>
        _t(isAr, 'حدث خطأ غير متوقع', 'Something went wrong'),
    };

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog(
      {required this.progress, required this.cancel, required this.isAr});

  final ValueNotifier<ReportProgress> progress;
  final ReportCancelToken cancel;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: ValueListenableBuilder<ReportProgress>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_t(isAr, 'جاري إنشاء التقرير…', 'Generating report…')),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value.fraction),
            const SizedBox(height: 8),
            Text(_stageText(value.stage, isAr),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: cancel.cancel,
          child: Text(_t(isAr, 'إلغاء', 'Cancel')),
        ),
      ],
    );
  }

  String _stageText(ReportStage stage, bool isAr) => switch (stage) {
        ReportStage.collecting => _t(isAr, 'جمع البيانات', 'Collecting data'),
        ReportStage.composing => _t(isAr, 'حساب المؤشرات', 'Computing metrics'),
        ReportStage.rendering => _t(isAr, 'رسم الصفحات', 'Rendering pages'),
        ReportStage.writing => _t(isAr, 'حفظ الملف', 'Saving file'),
        ReportStage.ready => _t(isAr, 'اكتمل', 'Done'),
        _ => '',
      };
}
