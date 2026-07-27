import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../data/reporting/report_snapshot_builder.dart';
import '../../../domain/reporting/report_request.dart';
import '../pdf/report_fonts.dart';
import '../services/report_file_service.dart';
import '../services/report_generation_controller.dart';

/// Riverpod wiring for the report engine. These providers only *assemble*
/// dependency-injected objects (built from the app's existing repository
/// providers); the objects themselves are Riverpod-free and unit-tested.

/// Reads the three repositories the snapshot builder needs, in one place.
final reportSnapshotBuilderProvider = Provider<ReportSnapshotBuilder>((ref) {
  return ReportSnapshotBuilder(
    transactions: ref.watch(transactionRepositoryProvider),
    accounts: ref.watch(accountRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    budgets: ref.watch(budgetProgressUseCaseProvider),
    bills: ref.watch(billRepositoryProvider),
    goals: ref.watch(goalRepositoryProvider),
  );
});

final reportFileServiceProvider =
    Provider<ReportFileService>((ref) => ReportFileService());

/// The orchestrator the UI drives (generate / progress / cancel / retry).
/// Fonts are loaded on the main isolate via [ReportFonts.load].
final reportGenerationControllerProvider =
    Provider<ReportGenerationController>((ref) {
  return ReportGenerationController(
    builder: ref.watch(reportSnapshotBuilderProvider),
    fileService: ref.watch(reportFileServiceProvider),
    loadFonts: ReportFonts.load,
    loadFontBytes: ReportFonts.loadBytes, // render off the main isolate
    loadLogoBytes: ReportFonts.loadLogoBytes,
  );
});

/// The in-progress report configuration edited by the config sheet. Defaults to
/// a monthly, all-accounts report; the sheet pre-fills language/privacy from the
/// user's settings when opened.
final reportRequestProvider = StateProvider<ReportRequest>((ref) {
  return const ReportRequest(period: MonthlyPeriod());
});
