import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/exporting/export_file_protector.dart';
import 'package:money_companion/core/exporting/managed_export_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/reporting/date_range.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/pdf/report_fonts.dart';
import 'package:money_companion/features/reporting/services/report_file_service.dart';
import 'package:money_companion/features/reporting/services/report_generation_controller.dart';
import 'package:pdf/widgets.dart' as pw;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late ReportSnapshotBuilder builder;
  late ReportFileService fileService;
  late ReportGenerationController controller;
  var tick = 0;

  DateTime clock() => DateTime(2026, 7, 27, 12, 0, tick++);

  pw.Font fontFrom(String file) =>
      pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()));
  Future<ReportFontSet> loadFonts() async => ReportFontSet(
        regular: fontFrom('IBMPlexSansArabic-Regular.ttf'),
        medium: fontFrom('IBMPlexSansArabic-Medium.ttf'),
        semiBold: fontFrom('IBMPlexSansArabic-SemiBold.ttf'),
        bold: fontFrom('IBMPlexSansArabic-Bold.ttf'),
      );

  Future<void> put(String id, double amount, TransactionTypeEntity type, DateTime at,
      {String? categoryKey}) {
    return txRepo.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amount: amount,
        currency: 'SAR',
        type: type,
        source: TransactionSourceEntity.bank,
        occurredAt: at,
        rawMessage: 'seed',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: at,
        updatedAt: at,
      ),
      categoryKey: categoryKey,
    );
  }

  setUp(() async {
    tick = 0;
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
    builder = ReportSnapshotBuilder(
      transactions: txRepo,
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      clock: clock,
    );
    fileService = ReportFileService(
      store: ManagedExportStore(
        baseDirectory: () => Directory.systemTemp.createTemp('report_test_'),
        protector: const NoopExportFileProtector(),
      ),
    );
    controller = ReportGenerationController(
      fileService: fileService,
      loadFonts: loadFonts,
      builder: builder,
    );
    await put('inc', 12400, TransactionTypeEntity.income, DateTime.utc(2026, 7, 5));
    await put('exp', 8730, TransactionTypeEntity.payment, DateTime.utc(2026, 7, 10),
        categoryKey: 'groceries');
  });

  tearDown(() async => db.close());

  test('generate produces a valid PDF file and ordered progress', () async {
    final stages = <ReportStage>[];
    final result = await controller.generate(
      const ReportRequest(period: MonthlyPeriod()),
      onProgress: (p) => stages.add(p.stage),
    );

    expect(await result.export.file.exists(), isTrue);
    expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
    expect(
      stages,
      containsAllInOrder(<ReportStage>[
        ReportStage.collecting,
        ReportStage.composing,
        ReportStage.rendering,
        ReportStage.writing,
        ReportStage.ready,
      ]),
    );
    await fileService.dispose(result.export);
  });

  test('renders off a background isolate when font bytes are provided', () async {
    Uint8List b(String f) => File('assets/fonts/$f').readAsBytesSync();
    final isolateController = ReportGenerationController(
      fileService: fileService,
      loadFonts: loadFonts, // fallback, unused when bytes are provided
      loadFontBytes: () async => ReportFontBytes(
        regular: b('IBMPlexSansArabic-Regular.ttf'),
        medium: b('IBMPlexSansArabic-Medium.ttf'),
        semiBold: b('IBMPlexSansArabic-SemiBold.ttf'),
        bold: b('IBMPlexSansArabic-Bold.ttf'),
      ),
      builder: builder,
    );
    final result =
        await isolateController.generate(const ReportRequest(period: MonthlyPeriod()));
    expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
    await fileService.dispose(result.export);
  });

  test('a pre-cancelled token aborts with the cancelled error', () async {
    final token = ReportCancelToken()..cancel();
    await expectLater(
      controller.generate(const ReportRequest(period: MonthlyPeriod()), cancel: token),
      throwsA(isA<ReportGenerationException>()
          .having((e) => e.kind, 'kind', ReportErrorKind.cancelled)),
    );
  });

  test('font load failure surfaces as fontLoadFailed', () async {
    final failing = ReportGenerationController(
      fileService: fileService,
      loadFonts: () async => throw StateError('no fonts'),
      builder: builder,
    );
    await expectLater(
      failing.generate(const ReportRequest(period: MonthlyPeriod())),
      throwsA(isA<ReportGenerationException>()
          .having((e) => e.kind, 'kind', ReportErrorKind.fontLoadFailed)),
    );
  });

  test('reuseSnapshot skips a second data collection', () async {
    final first = await controller.generate(const ReportRequest(period: MonthlyPeriod()));
    final second = await controller.generate(
      const ReportRequest(period: MonthlyPeriod()),
      reuseSnapshot: true,
    );
    // The clock ticks per collection; an equal capturedAt proves no re-collect.
    expect(second.snapshot.capturedAt, first.snapshot.capturedAt);
    await fileService.dispose(first.export);
    await fileService.dispose(second.export);
  });

  test('fileName is safe, ASCII-only, and deterministic', () {
    final name = fileService.fileName(
      DateRange(DateTime(2026, 7), DateTime(2026, 8)),
      DateTime(2026, 7, 27, 12),
    );
    expect(name, 'Qirsh-Report-20260701-20260731-2026-07-27-12-00-00.pdf');
    expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name), isTrue);
  });
}
