import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../core/exporting/managed_export_store.dart';
import '../services/report_file_service.dart';

/// Previews a generated report before sharing. The PDF is rendered with
/// `printing`'s [PdfPreview]; sharing is gated by a privacy warning when the
/// report is unmasked, and print goes through the system dialog.
///
/// MALI-065n: the managed temp PDF is deleted the moment this preview is
/// dismissed (see [State.dispose]) — covering the share-cancelled and
/// share-failed paths equally, since we never rely on knowing the outcome — and
/// the bounded-lease sweep reclaims it if the process is killed while open.
class ReportPreviewScreen extends StatefulWidget {
  const ReportPreviewScreen({
    super.key,
    required this.bytes,
    required this.export,
    required this.fileService,
    this.containsSensitive = true,
  });

  final Uint8List bytes;
  final ManagedExport export;
  final ReportFileService fileService;

  /// Whether the report shows unmasked sensitive data (drives the share warning).
  final bool containsSensitive;

  @override
  State<ReportPreviewScreen> createState() => _ReportPreviewScreenState();
}

class _ReportPreviewScreenState extends State<ReportPreviewScreen> {
  @override
  void dispose() {
    // The export has done its job once the user leaves the preview. Delete it
    // now (idempotent, best-effort); the sweep is the crash backstop.
    widget.fileService.dispose(widget.export);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode != 'en';
    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'معاينة التقرير' : 'Report preview')),
      body: PdfPreview(
        build: (_) async => widget.bytes,
        useActions: false,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _share(context, isAr),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(isAr ? 'مشاركة' : 'Share'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => widget.fileService.printPdf(widget.bytes),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: Text(isAr ? 'طباعة' : 'Print'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context, bool isAr) async {
    if (widget.containsSensitive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(isAr ? 'مشاركة بيانات مالية' : 'Share financial data'),
          content: Text(isAr
              ? 'يحتوي هذا التقرير على أرصدة وأسماء متاجر. هل تريد مشاركته؟'
              : 'This report contains account balances and merchant names. Share it anyway?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(isAr ? 'مشاركة' : 'Share'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box != null ? box.localToGlobal(Offset.zero) & box.size : null;
    await widget.fileService.share(
      widget.export,
      origin: origin,
      subject: isAr ? 'التقرير المالي' : 'Financial Report',
    );
  }
}
