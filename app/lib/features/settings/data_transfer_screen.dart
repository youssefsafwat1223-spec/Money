import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/backup/backup_service.dart';
import '../../core/data_portability/data_portability_models.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/account_entity.dart';
import '../../core/theme/widgets/app_toast.dart';

class DataTransferScreen extends ConsumerStatefulWidget {
  const DataTransferScreen({super.key, this.initialAction});

  final String? initialAction;

  @override
  ConsumerState<DataTransferScreen> createState() => _DataTransferScreenState();
}

class _DataTransferScreenState extends ConsumerState<DataTransferScreen> {
  ImportPreview? _preview;
  ImportMode _mode = ImportMode.merge;
  ImportResult? _result;
  bool _busy = false;
  bool _legacyBackupExists = false;

  @override
  void initState() {
    super.initState();
    _checkLegacyBackup();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runInitialAction();
    });
  }

  Future<void> _runInitialAction() async {
    await _waitForRouteTransition();
    if (!mounted) return;
    switch (widget.initialAction) {
      case 'import':
        await _pickFile();
      case 'transactions':
        await _export(fullPackage: false);
      case 'package':
        await _export(fullPackage: true);
    }
  }

  Future<void> _waitForRouteTransition() async {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return;
    }
    final completer = Completer<void>();
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (!completer.isCompleted) completer.complete();
      }
    }

    animation.addStatusListener(listener);
    if (animation.status == AnimationStatus.completed &&
        !completer.isCompleted) {
      completer.complete();
    }
    try {
      await completer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // A custom route may not report completion; one second is still safely
      // beyond the standard iOS and Material navigation transitions.
    } finally {
      animation.removeStatusListener(listener);
    }
  }

  Future<void> _checkLegacyBackup() async {
    if (!SupabaseConfig.isConfigured) return;
    try {
      final exists = await ref.read(backupServiceProvider).hasRemoteBackup();
      if (mounted) setState(() => _legacyBackupExists = exists);
    } catch (_) {}
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'zip'],
        allowMultiple: false,
        withData: false,
      );
      final path = picked?.files.single.path;
      if (path == null || !mounted) return;

      setState(() {
        _result = null;
      });

      final preview =
          await ref.read(dataPortabilityServiceProvider).inspectFile(path);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _mode = ImportMode.merge;
      });
    } on DataPortabilityException catch (error) {
      _message(error.message);
    } catch (_) {
      _message('تعذر فحص الملف. تأكد أنه CSV أو ZIP صالح.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runImport() async {
    final preview = _preview;
    if (preview == null || _busy) return;
    if (_mode == ImportMode.replace && !await _confirmReplace()) return;
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(dataPortabilityServiceProvider).import(preview, _mode);
      if (!mounted) return;
      setState(() => _result = result);
    } on DataPortabilityException catch (error) {
      _message(error.message);
    } catch (_) {
      _message('تعذر إكمال الاستيراد. لم تُحذف أي بيانات غير مؤكدة.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace() async {
    return showReplaceConfirmationDialog(context);
  }

  Future<void> _export({required bool fullPackage}) async {
    if (_busy) return;
    setState(() => _busy = true);
    File? tempFile;
    ExportedFile exported;
    try {
      final service = ref.read(dataPortabilityServiceProvider);
      exported = fullPackage
          ? await service.exportFinancialPackage()
          : await service.exportTransactionsCsv();
    } on DataPortabilityException catch (error, stackTrace) {
      _logExportFailure('prepare', error, stackTrace);
      _message(error.message);
      if (mounted) setState(() => _busy = false);
      return;
    } catch (error, stackTrace) {
      _logExportFailure('prepare', error, stackTrace);
      _message('تعذر قراءة البيانات وتجهيز ملف التصدير.');
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final directory = await getTemporaryDirectory();
      tempFile = File('${directory.path}/${exported.name}');
      await tempFile.writeAsBytes(exported.bytes, flush: true);
    } catch (error, stackTrace) {
      _logExportFailure('write', error, stackTrace);
      try {
        await tempFile?.delete();
      } catch (_) {}
      _message('تعذر حفظ ملف التصدير مؤقتًا على الجهاز.');
      if (mounted) setState(() => _busy = false);
      return;
    }

    if (!mounted) {
      try {
        await tempFile.delete();
      } catch (_) {}
      return;
    }

    try {
      final overlayBox = Overlay.of(context).context.findRenderObject();
      final shareOrigin = overlayBox is RenderBox && overlayBox.hasSize
          ? overlayBox.localToGlobal(Offset.zero) & overlayBox.size
          : null;
      await Share.shareXFiles(
        [
          XFile(tempFile.path, mimeType: exported.mimeType, name: exported.name)
        ],
        subject: fullPackage ? 'Qirsh financial data' : 'Qirsh transactions',
        text: fullPackage
            ? 'ملف بيانات قرش المالية. احتفظ به في مكان خاص.'
            : 'تصدير عمليات قرش بصيغة CSV.',
        sharePositionOrigin: shareOrigin,
        fileNameOverrides: [exported.name],
      );
    } catch (error, stackTrace) {
      _logExportFailure('share', error, stackTrace);
      _message('تم تجهيز الملف، لكن تعذر فتح نافذة المشاركة. حاول مرة أخرى.');
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logExportFailure(
    String stage,
    Object error,
    StackTrace stackTrace,
  ) {
    assert(() {
      debugPrint(
          '[DataTransfer] export failed stage=$stage type=${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      return true;
    }());
  }

  void _message(String text) {
    if (!mounted) return;
    AppToast.show(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(title: const Text('نقل البيانات')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              Text(
                'استورد بياناتك أو احتفظ بنسخة قابلة للنقل. تتم معاينة الملف على جهازك قبل أي كتابة.',
                style: AppTypography.body(colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s5),
              _ActionTile(
                icon: Icons.file_open_outlined,
                title: 'استيراد ملف',
                subtitle: 'CSV من أي تطبيق أو ZIP صادر من قرش',
                onTap: _pickFile,
              ),
              _ActionTile(
                icon: Icons.table_view_outlined,
                title: 'تصدير العمليات CSV',
                subtitle: 'ملف واحد متوافق مع Excel وتطبيقات الميزانية',
                onTap: () => _export(fullPackage: false),
              ),
              _ActionTile(
                icon: Icons.archive_outlined,
                title: 'تصدير كل بيانات قرش ZIP',
                subtitle: 'الحسابات والعمليات والميزانيات والخطط المالية',
                onTap: () => _export(fullPackage: true),
              ),
              if (_legacyBackupExists)
                _ActionTile(
                  icon: Icons.settings_backup_restore_outlined,
                  title: 'استعادة نسخة قديمة',
                  subtitle: 'متاح مؤقتاً للنسخ المشفرة التي أنشأتها سابقاً',
                  onTap: () => context.push('/backup/restore'),
                ),
              if (_preview != null) ...[
                const SizedBox(height: AppSpacing.s6),
                _PreviewPanel(
                  preview: _preview!,
                  mode: _mode,
                  accounts: ref.watch(accountsProvider).valueOrNull ?? const [],
                  onPreviewChanged: (value) => setState(() => _preview = value),
                  onModeChanged: (value) => setState(() => _mode = value),
                  onImport: _runImport,
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: AppSpacing.s5),
                _ResultPanel(result: _result!),
              ],
              const SizedBox(height: AppSpacing.s8),
              Text(
                'ملفات التصدير لا تحتوي رسائل البنك الخام أو بيانات الدخول أو رموز الأجهزة. ملف ZIP غير محمي بكلمة مرور؛ خزّنه في مكان خاص.',
                style: AppTypography.caption(colors.textSecondary),
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x22000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

@visibleForTesting
Future<bool> showReplaceConfirmationDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _ReplaceConfirmationDialog(),
  );
  return result ?? false;
}

class _ReplaceConfirmationDialog extends StatefulWidget {
  const _ReplaceConfirmationDialog();

  @override
  State<_ReplaceConfirmationDialog> createState() =>
      _ReplaceConfirmationDialogState();
}

class _ReplaceConfirmationDialogState
    extends State<_ReplaceConfirmationDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop(_controller.text.trim() == 'استبدال');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تأكيد الاستبدال'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'سيتم إخفاء بياناتك المالية الحالية واستبدالها بمحتوى حزمة قرش. اكتب «استبدال» للمتابعة.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _confirm(),
            decoration: const InputDecoration(labelText: 'اكتب استبدال'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('تأكيد'),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_left),
        onTap: onTap,
      );
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.preview,
    required this.mode,
    required this.accounts,
    required this.onPreviewChanged,
    required this.onModeChanged,
    required this.onImport,
  });

  final ImportPreview preview;
  final ImportMode mode;
  final List<AccountEntity> accounts;
  final ValueChanged<ImportPreview> onPreviewChanged;
  final ValueChanged<ImportMode> onModeChanged;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    ImportPreview remapped(CsvColumnMapping mapping) => preview.copyWith(
          mapping: mapping,
          issues: preview.issues
              .where((issue) => issue.severity == ImportIssueSeverity.warning)
              .toList(growable: false),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('معاينة الاستيراد',
                style: AppTypography.headline(colors.textMain)),
            const SizedBox(height: 8),
            Text(
                '${preview.totalRows} سجل • ${preview.format == ImportFormat.qirshPackage ? 'حزمة قرش' : 'CSV'}'),
            if (preview.format == ImportFormat.qirshPackage) ...[
              const SizedBox(height: 8),
              for (final entry in preview.tableCounts.entries)
                Text('${entry.key}: ${entry.value}'),
            ],
            if (preview.format == ImportFormat.genericCsv &&
                preview.mapping != null) ...[
              const SizedBox(height: 16),
              _MappingField(
                label: 'عمود التاريخ',
                value: preview.mapping!.dateColumn,
                headers: preview.headers,
                onChanged: (value) => onPreviewChanged(
                  remapped(preview.mapping!.copyWith(dateColumn: value)),
                ),
              ),
              _MappingField(
                label: 'عمود المبلغ',
                value: preview.mapping!.amountColumn,
                headers: preview.headers,
                onChanged: (value) => onPreviewChanged(
                  remapped(preview.mapping!.copyWith(amountColumn: value)),
                ),
              ),
              if (accounts.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: preview.defaultAccountId,
                  decoration:
                      const InputDecoration(labelText: 'الحساب الافتراضي'),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem<String>(
                        value: account.id,
                        child: Text('${account.name} • ${account.currency}'),
                      ),
                  ],
                  onChanged: (value) => onPreviewChanged(
                    preview.copyWith(defaultAccountId: value),
                  ),
                ),
              _OptionalMappingField(
                label: 'الخصم (Debit)',
                value: preview.mapping!.debitColumn,
                headers: preview.headers,
                onChanged: (value) => onPreviewChanged(
                  remapped(preview.mapping!.copyWith(debitColumn: value)),
                ),
              ),
              _OptionalMappingField(
                label: 'الإيداع (Credit)',
                value: preview.mapping!.creditColumn,
                headers: preview.headers,
                onChanged: (value) => onPreviewChanged(
                  remapped(preview.mapping!.copyWith(creditColumn: value)),
                ),
              ),
              for (final spec
                  in <(String, String?, CsvColumnMapping Function(String))>[
                (
                  'العملة',
                  preview.mapping!.currencyColumn,
                  (value) => preview.mapping!.copyWith(currencyColumn: value)
                ),
                (
                  'الحساب',
                  preview.mapping!.accountColumn,
                  (value) => preview.mapping!.copyWith(accountColumn: value)
                ),
                (
                  'التاجر / الوصف',
                  preview.mapping!.merchantColumn,
                  (value) => preview.mapping!.copyWith(merchantColumn: value)
                ),
                (
                  'التصنيف',
                  preview.mapping!.categoryColumn,
                  (value) => preview.mapping!.copyWith(categoryColumn: value)
                ),
                (
                  'الملاحظات',
                  preview.mapping!.noteColumn,
                  (value) => preview.mapping!.copyWith(noteColumn: value)
                ),
                (
                  'نوع العملية',
                  preview.mapping!.typeColumn,
                  (value) => preview.mapping!.copyWith(typeColumn: value)
                ),
              ])
                _OptionalMappingField(
                  label: spec.$1,
                  value: spec.$2,
                  headers: preview.headers,
                  onChanged: (value) => onPreviewChanged(
                    remapped(spec.$3(value)),
                  ),
                ),
              DropdownButtonFormField<ImportDateFormat>(
                value: preview.mapping!.dateFormat,
                decoration: const InputDecoration(labelText: 'صيغة التاريخ'),
                items: const [
                  DropdownMenuItem(
                      value: ImportDateFormat.automatic,
                      child: Text('تلقائية')),
                  DropdownMenuItem(
                      value: ImportDateFormat.dayMonthYear,
                      child: Text('يوم / شهر / سنة')),
                  DropdownMenuItem(
                      value: ImportDateFormat.monthDayYear,
                      child: Text('شهر / يوم / سنة')),
                  DropdownMenuItem(
                      value: ImportDateFormat.yearMonthDay,
                      child: Text('سنة / شهر / يوم')),
                  DropdownMenuItem(
                      value: ImportDateFormat.iso8601, child: Text('ISO-8601')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  onPreviewChanged(remapped(
                    preview.mapping!.copyWith(dateFormat: value),
                  ));
                },
              ),
              if (preview.mapping!.accountColumn != null ||
                  preview.mapping!.categoryColumn != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'عند التأكيد، سيُنشئ قرش الحسابات والتصنيفات غير الموجودة الواردة في الملف.',
                    style: AppTypography.caption(colors.textSecondary),
                  ),
                ),
              if (preview.duplicateRecordIds.isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      'استيراد ${preview.duplicateRecordIds.length} عملية مشابهة كعمليات جديدة'),
                  value: preview.confirmedDuplicateRecordIds.length ==
                      preview.duplicateRecordIds.length,
                  onChanged: (enabled) => onPreviewChanged(preview.copyWith(
                    confirmedDuplicateRecordIds:
                        enabled ? preview.duplicateRecordIds : const {},
                  )),
                ),
            ],
            if (preview.canReplace) ...[
              const SizedBox(height: 16),
              SegmentedButton<ImportMode>(
                segments: const [
                  ButtonSegment(value: ImportMode.merge, label: Text('دمج')),
                  ButtonSegment(
                      value: ImportMode.replace, label: Text('استبدال')),
                ],
                selected: {mode},
                onSelectionChanged: (value) => onModeChanged(value.first),
              ),
            ],
            if (preview.issues.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final issue in preview.issues.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${issue.rowNumber == null ? '' : 'صف ${issue.rowNumber}: '}${issue.message}',
                    style: AppTypography.caption(
                      issue.severity == ImportIssueSeverity.error
                          ? colors.danger
                          : colors.textSecondary,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: preview.hasErrors ? null : onImport,
              icon: const Icon(Icons.download_done_outlined),
              label: const Text('تأكيد الاستيراد'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MappingField extends StatelessWidget {
  const _MappingField({
    required this.label,
    required this.value,
    required this.headers,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> headers;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final header in headers)
            DropdownMenuItem(value: header, child: Text(header)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      );
}

class _OptionalMappingField extends StatelessWidget {
  const _OptionalMappingField({
    required this.label,
    required this.value,
    required this.headers,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> headers;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        value: headers.contains(value) ? value : null,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final header in headers)
            DropdownMenuItem(value: header, child: Text(header)),
        ],
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      );
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});
  final ImportResult result;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('اكتمل الاستيراد',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('تمت الإضافة: ${result.imported}'),
          Text('مكرر: ${result.duplicates}'),
          Text('متجاهل: ${result.skipped}'),
          Text('فشل: ${result.failed}'),
          if (result.cacheRepairPending)
            const Text(
                'تم الحفظ على الخادم، وسيُصلح قرش الكاش المحلي تلقائياً.'),
        ],
      );
}
