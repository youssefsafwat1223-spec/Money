// Debug-only negative outcomes for the real report generation UI.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/providers/report_providers.dart';
import 'package:money_companion/features/reporting/services/report_file_service.dart';
import 'package:money_companion/features/reporting/services/report_generation_controller.dart';
import 'package:money_companion/features/reporting/ui/report_config_page.dart';

class ReportGenerationReview extends StatelessWidget {
  const ReportGenerationReview({super.key, required this.waitForCancel});

  final bool waitForCancel;

  @override
  Widget build(BuildContext context) => ProviderScope(
        overrides: [
          reportGenerationControllerProvider.overrideWithValue(
            _RejectedGeneration(waitForCancel),
          ),
          reportFileServiceProvider.overrideWithValue(_NoExport()),
        ],
        child: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => unawaited(runReportGeneration(
                  context,
                  ref,
                  const ReportRequest(period: MonthlyPeriod()),
                )),
                child: const Text('Start report QA'),
              ),
            ),
          ),
        ),
      );
}

class _NoExport extends ReportFileService {
  @override
  Future<void> sweepStale({Duration olderThan = const Duration(hours: 1)}) async {}
}

class _RejectedGeneration implements ReportGenerationController {
  _RejectedGeneration(this.waitForCancel);

  final bool waitForCancel;

  @override
  void invalidate() {}

  @override
  Future<ReportResult> generate(
    ReportRequest request, {
    void Function(ReportProgress)? onProgress,
    ReportCancelToken? cancel,
    bool reuseSnapshot = false,
  }) async {
    for (var i = 0; i < (waitForCancel ? 160 : 24); i++) {
      if (cancel?.isCancelled ?? false) {
        throw ReportGenerationException(ReportErrorKind.cancelled);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw ReportGenerationException(ReportErrorKind.renderFailed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
