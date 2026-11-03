// Offline visual QA only; never imported by lib/. Uses the real report engine
// and preview. Run the PDF skill's artifact marker before invoking this helper.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/providers/report_providers.dart';
import 'package:money_companion/features/reporting/ui/report_preview_screen.dart';

bool _generating = false;
Map<String, Object?>? _lastReport;

/// The path is a synthetic, managed Simulator export. Copy it for read-only PDF
/// inspection while the preview is open; the normal screen disposes it on exit.
Map<String, Object?>? visualParityLastReport() =>
    _lastReport == null ? null : Map.unmodifiable(_lastReport!);

Future<bool> openVisualParityReportPreview(
    BuildContext context, WidgetRef ref, {bool invalidPreview = false}) async {
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('visual_report_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('visual_report_requires_memory_database');
  }
  // Do not substitute another account or invent a success for an empty fixture.
  final account = await ref.read(accountRepositoryProvider).getById('p-acc-1');
  if (account == null || !context.mounted || _generating) return false;
  final fileService = ref.read(reportFileServiceProvider);
  final controller = ref.read(reportGenerationControllerProvider)..invalidate();
  final now = DateTime.now();
  final request = ReportRequest(
    period: CustomPeriod(from: now.subtract(const Duration(days: 30)), to: now),
    scope: const SingleAccountScope('p-acc-1'),
    languageCode: Localizations.localeOf(context).languageCode,
    privacyMode: false,
    content: const ReportContentOptions(includeTransactionDetails: true),
  );
  _generating = true;
  _lastReport = null;
  try {
    final result = await controller.generate(request);
    if (!context.mounted) {
      await fileService.dispose(result.export);
      return false;
    }
    _lastReport = {
      'fixture': 'synthetic-memory',
      'path': result.export.file.path,
      'bytes': result.bytes.length,
      'language': request.languageCode,
      'accountId': request.accountId,
      'from': (request.period as CustomPeriod).from.toIso8601String(),
      'to': now.toIso8601String(),
      'previewOpen': true,
    };
    try {
      final route = Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => ReportPreviewScreen(
          bytes: invalidPreview ? Uint8List.fromList([0, 1, 2, 3]) : result.bytes,
          export: result.export,
          fileService: fileService,
          containsSensitive: true,
        ),
      ));
      unawaited(route.then<void>((_) {
        if (_lastReport?['path'] == result.export.file.path) {
          _lastReport!['previewOpen'] = false;
        }
      }, onError: (Object error, StackTrace stack) async {
        await fileService.dispose(result.export);
        if (_lastReport?['path'] == result.export.file.path) {
          _lastReport!['previewOpen'] = false;
        }
        FlutterError.reportError(FlutterErrorDetails(exception: error,
            stack: stack, library: 'Qirsh synthetic report preview'));
      }));
    } catch (_) {
      await fileService.dispose(result.export);
      rethrow;
    }
    return true;
  } finally {
    _generating = false;
  }
}
