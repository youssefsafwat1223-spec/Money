import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/report_file_service.dart';

/// Previews a generated report before sharing. The PDF is rendered with
/// `printing`'s [PdfPreview]; sharing is gated by a privacy warning when the
/// report is unmasked, and print goes through the system dialog.
class ReportPreviewScreen extends StatelessWidget {
  const ReportPreviewScreen({
    super.key,
    required this.bytes,
    required this.file,
    required this.fileService,
    this.containsSensitive = true,
  });

  final Uint8List bytes;
  final File file;
  final ReportFileService fileService;

  /// Whether the report shows unmasked sensitive data (drives the share warning).
  final bool containsSensitive;

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode != 'en';
    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'معاينة التقرير' : 'Report preview')),
      body: PdfPreview(
        build: (_) async => bytes,
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
                  onPressed: () => fileService.printPdf(bytes),
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
    if (containsSensitive) {
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
    await fileService.share(
      file,
      origin: origin,
      subject: isAr ? 'التقرير المالي' : 'Financial Report',
    );
  }
}
