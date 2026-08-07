// Phase-7 Batch-2-B closure §Blocker-1 — the appendix-omission is VISIBLE in the
// rendered report, not merely an internal flag. When the period exceeds the 5000-row
// appendix bound the composed view model carries appendixOmitted + the localized
// notice (Arabic AND English), and the PDF renders (the omission page is emitted).
// At/under the bound there is no omission and the detailed appendix is present.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/composition/report_composer.dart';
import 'package:money_companion/features/reporting/pdf/report_fonts.dart';
import 'package:money_companion/features/reporting/pdf/report_pdf_renderer.dart';
import 'package:money_companion/features/reporting/pdf/report_theme_spec.dart';
import 'package:pdf/widgets.dart' as pw;

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const theme = ReportThemeSpec();
  const composer = ReportComposer();
  final renderer = ReportPdfRenderer(
    logoBytes: File('assets/qirsh/qirsh_coin.png').readAsBytesSync(),
  );
  pw.Font fontFrom(String f) =>
      pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync()));
  final fonts = ReportFontSet(
    regular: fontFrom('IBMPlexSansArabic-Regular.ttf'),
    medium: fontFrom('IBMPlexSansArabic-Medium.ttf'),
    semiBold: fontFrom('IBMPlexSansArabic-SemiBold.ttf'),
    bold: fontFrom('IBMPlexSansArabic-Bold.ttf'),
  );

  late AppDatabase db;

  Future<ReportSnapshotBuilder> builderWith(int count) async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'A', 'SAR', 'bank', '2026-06-01', '2026-06-01');",
    );
    final base = DateTime.utc(2026, 6, 2);
    await db.transaction(() async {
      for (var i = 0; i < count; i++) {
        final occ = dateTimeToSql(base.add(Duration(seconds: i)));
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, type, source, "
          "occurred_at, raw_message, parse_confidence, status, created_at, "
          "updated_at) VALUES ('t${i.toString().padLeft(6, '0')}', ${10 + i}, "
          "'SAR', 'a0', 'payment', 'bank', '$occ', 'r', 0.9, 'confirmed', "
          "'$occ', '$occ');",
        );
      }
    });
    return ReportSnapshotBuilder(
      transactions: DriftTransactionRepository(db),
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      clock: () => DateTime(2026, 6, 15, 12),
    );
  }

  tearDown(() => db.close());

  ReportRequest req(String lang) => ReportRequest(
        period: const MonthlyPeriod(),
        languageCode: lang,
        content: const ReportContentOptions(includeTransactionDetails: true),
      );

  test('5001 rows: omission is composed + rendered (Arabic AND English)', () async {
    final b = await builderWith(5001);
    for (final lang in ['ar', 'en']) {
      final snap = await b.build(req(lang));
      expect(snap.appendixOmittedForSize, isTrue);
      final vm = composer.compose(snap);
      expect(vm.appendixOmitted, isTrue);
      expect(vm.appendix, isEmpty);
      // The visible, localized notice the renderer will draw.
      expect(vm.strings.appendixOmittedNotice, isNotEmpty);
      expect(
        vm.strings.appendixOmittedNotice,
        lang == 'ar' ? contains('حذف الملحق') : contains('appendix was omitted'),
      );
      // Renders end-to-end (the omission page is emitted) → non-empty PDF.
      final bytes =
          await renderer.render(model: vm, fonts: fonts, theme: theme);
      expect(bytes, isNotEmpty);
    }
  });

  test('4999 rows: no omission, detailed appendix present', () async {
    final b = await builderWith(4999);
    final snap = await b.build(req('ar'));
    expect(snap.appendixOmittedForSize, isFalse);
    final vm = composer.compose(snap);
    expect(vm.appendixOmitted, isFalse);
    expect(vm.appendix, isNotEmpty);
  });
}
