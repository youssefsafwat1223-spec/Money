import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/exporting/managed_export_store.dart';
import '../../../domain/reporting/date_range.dart';

/// Names, shares, prints, and cleans up generated report files.
///
/// The temp-file lifecycle is delegated to the shared [ManagedExportStore]
/// (MALI-065n): reports are written to a private managed directory with opaque,
/// data-free on-disk names + platform file-protection, deleted when the preview
/// closes (success/cancel/failure), and reclaimed by the bounded-lease sweep if
/// a crash orphans one. The friendly, date-based share name is presented only
/// in the share sheet.
class ReportFileService {
  ReportFileService({ManagedExportStore? store})
      : _store = store ?? ManagedExportStore();

  final ManagedExportStore _store;

  /// Brand slug for the share name. Kept a constant so it flips to "Mali" the
  /// moment an official Mali mark exists (see plan open decision #13).
  static const String _brand = 'Qirsh';

  /// A safe, ASCII-only, collision-resistant share name, e.g.
  /// `Qirsh-Report-20260701-20260731-2026-07-27-12-00-00.pdf`. Contains only
  /// the period and generation time — never an amount, merchant, or balance.
  String fileName(DateRange range, DateTime generatedAt) {
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';
    final lastDay = range.to.subtract(const Duration(days: 1));
    final stamp = generatedAt
        .toIso8601String()
        .split('.')
        .first
        .replaceAll(RegExp('[:T]'), '-');
    return '$_brand-Report-${ymd(range.from)}-${ymd(lastDay)}-$stamp.pdf';
  }

  /// Writes [bytes] to a managed temp file and returns its handle. [shareName]
  /// is the friendly name for the share sheet (see [fileName]).
  Future<ManagedExport> writeReport(Uint8List bytes, String shareName) {
    return _store.writeBytes(
      bytes,
      shareName: shareName,
      extension: 'pdf',
      mimeType: 'application/pdf',
    );
  }

  /// Deletes a managed report export. Idempotent; never throws. Call when the
  /// preview is dismissed.
  Future<void> dispose(ManagedExport export) => _store.dispose(export);

  /// Bounded-lease sweep of report exports orphaned by a crash mid-share.
  Future<void> sweepStale({
    Duration olderThan = ManagedExportStore.defaultLease,
  }) =>
      _store.sweep(olderThan: olderThan);

  /// Opens the system share sheet with [export]. [origin] is the iPad popover
  /// anchor (from the share button's `RenderBox`).
  Future<void> share(
    ManagedExport export, {
    Rect? origin,
    String? subject,
    String? text,
  }) {
    return Share.shareXFiles(
      <XFile>[
        XFile(export.file.path,
            mimeType: export.mimeType, name: export.shareName),
      ],
      subject: subject,
      text: text,
      sharePositionOrigin: origin,
    );
  }

  /// Opens the system print dialog (AirPrint / Android print framework).
  Future<void> printPdf(Uint8List bytes, {String name = 'report'}) {
    return Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
  }
}
