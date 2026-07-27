import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../domain/reporting/date_range.dart';

/// Writes, names, shares, prints, and cleans up generated report files.
///
/// Reports are **ephemeral** by default (temp directory), matching the app's
/// existing CSV/backup export pattern (write → share → delete in `finally`).
/// The temp-directory lookup is injectable so the naming/lifecycle logic is
/// testable without a platform channel.
class ReportFileService {
  ReportFileService({Future<Directory> Function()? temporaryDirectory})
      : _temporaryDirectory =
            temporaryDirectory ?? getTemporaryDirectory;

  final Future<Directory> Function() _temporaryDirectory;

  /// Brand slug for filenames. Kept a constant so it flips to "Mali" the moment
  /// an official Mali mark exists (see plan open decision #13).
  static const String _brand = 'Qirsh';

  /// A safe, ASCII-only, collision-resistant filename, e.g.
  /// `Qirsh-Report-20260701-20260731-2026-07-27_12-00-00.pdf`.
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

  /// Writes [bytes] to a temp file named [name] and returns it.
  Future<File> writeTemporary(Uint8List bytes, String name) async {
    final dir = await _temporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Best-effort delete; never throws.
  Future<void> deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // ignore — cleanup must not surface errors.
    }
  }

  /// Removes stale `Qirsh-Report-*.pdf` temp files older than [olderThan]
  /// (best-effort startup sweep; there is no app-wide temp sweeper otherwise).
  Future<void> sweepStale({
    Duration olderThan = const Duration(hours: 6),
    DateTime Function()? now,
  }) async {
    try {
      final dir = await _temporaryDirectory();
      final cutoff = (now ?? DateTime.now).call().subtract(olderThan);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.last;
        if (!base.startsWith('$_brand-Report-') || !base.endsWith('.pdf')) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await deleteQuietly(entity);
      }
    } catch (_) {
      // ignore — sweeping is best-effort.
    }
  }

  /// Opens the system share sheet with [file] as a PDF. [origin] is the iPad
  /// popover anchor (from the share button's `RenderBox`).
  Future<void> share(File file, {Rect? origin, String? subject, String? text}) {
    return Share.shareXFiles(
      <XFile>[
        XFile(file.path,
            mimeType: 'application/pdf', name: file.uri.pathSegments.last),
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
