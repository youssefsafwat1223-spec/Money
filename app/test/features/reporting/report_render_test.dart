import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/budget_progress_usecase.dart';
import 'package:money_companion/domain/reporting/report_data_snapshot.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/composition/report_composer.dart';
import 'package:money_companion/features/reporting/pdf/report_fonts.dart';
import 'package:money_companion/features/reporting/pdf/report_pdf_renderer.dart';
import 'package:money_companion/features/reporting/pdf/report_theme_spec.dart';
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

  const theme = ReportThemeSpec();
  const composer = ReportComposer();
  final renderer = ReportPdfRenderer(
    logoBytes: File('assets/qirsh/qirsh_coin.png').readAsBytesSync(),
  );

  DateTime clock() => DateTime(2026, 7, 27, 12);

  pw.Font fontFrom(String file) => pw.Font.ttf(
      ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()));

  ReportFontSet loadFonts() => ReportFontSet(
        regular: fontFrom('IBMPlexSansArabic-Regular.ttf'),
        medium: fontFrom('IBMPlexSansArabic-Medium.ttf'),
        semiBold: fontFrom('IBMPlexSansArabic-SemiBold.ttf'),
        bold: fontFrom('IBMPlexSansArabic-Bold.ttf'),
      );

  Future<void> put({
    required String id,
    required double amount,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    String currency = 'SAR',
    String? categoryKey,
    String? merchant,
  }) {
    return txRepo.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amountMoney: Money.fromLegacyReal(amount, currency),
        currency: currency,
        type: type,
        source: TransactionSourceEntity.bank,
        occurredAt: occurredAt,
        rawMessage: 'seed',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: occurredAt,
        updatedAt: occurredAt,
        rawMerchant: merchant,
      ),
      categoryKey: categoryKey,
    );
  }

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
    final budgetRepo = DriftBudgetRepository(db);
    final goalRepo = DriftGoalRepository(db);
    builder = ReportSnapshotBuilder(
      transactions: txRepo,
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      budgets: BudgetProgressUseCase(
          budgetRepository: budgetRepo, transactionRepository: txRepo),
      bills: DriftBillRepository(db),
      goals: goalRepo,
      clock: clock,
    );
    final groceriesId = (await DriftCategoryRepository(db).getAll())
        .firstWhere((c) => c.key == 'groceries')
        .id;
    await budgetRepo.save(BudgetEntity(
      id: 'bud-groc',
      categoryId: groceriesId,
      currency: 'SAR',
      amountMoney: Money.parse('1500', 'SAR'), // spent 1,980 → over budget
      period: BudgetPeriod.monthly,
      startDate: DateTime(2026, 7),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime(2026, 7),
    ));
    await goalRepo.save(GoalEntity(
      id: 'goal-1',
      name: 'صندوق الطوارئ',
      currency: 'SAR',
      targetMoney: Money.parse('20000', 'SAR'),
      savedMoney: Money.parse('13500', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: '',
      status: 'active',
      createdAt: clock(),
      deadline: DateTime(2026, 12, 31),
    ));

    // July (current): income 12,400 · expense 8,730 across categories + one
    // uncategorised payment (→ "Other" remainder).
    await put(
        id: 'jul-inc',
        amount: 12400,
        type: TransactionTypeEntity.income,
        occurredAt: DateTime.utc(2026, 7, 5));
    await put(
        id: 'jul-groc',
        amount: 1980,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 8),
        categoryKey: 'groceries',
        merchant: 'Panda');
    await put(
        id: 'jul-rest',
        amount: 1540,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 20),
        categoryKey: 'restaurants',
        merchant: 'Cheesecake Factory');
    await put(
        id: 'jul-bill',
        amount: 1320,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 6),
        categoryKey: 'bills',
        merchant: 'Electricity');
    await put(
        id: 'jul-shop',
        amount: 1150,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 14),
        categoryKey: 'shopping',
        merchant: 'IKEA');
    await put(
        id: 'jul-tran',
        amount: 980,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 11),
        categoryKey: 'transport',
        merchant: 'Uber');
    await put(
        id: 'jul-unc',
        amount: 1760,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 15));

    // June (previous): income 12,400 · expense 9,910 → savings 20% → +10pp, expense ▼11.9%.
    await put(
        id: 'jun-inc',
        amount: 12400,
        type: TransactionTypeEntity.income,
        occurredAt: DateTime.utc(2026, 6, 5));
    await put(
        id: 'jun-exp',
        amount: 9910,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 6, 15),
        categoryKey: 'groceries');
  });

  tearDown(() async => db.close());

  Future<ReportDataSnapshot> snapshotFor(String lang) => builder.build(
        ReportRequest(
          period: const MonthlyPeriod(),
          languageCode: lang,
          content: const ReportContentOptions(includeTransactionDetails: true),
        ),
      );

  test('renders a full Arabic report PDF from real data', () async {
    final snap = await snapshotFor('ar');
    final vm = composer.compose(snap);
    final bytes =
        await renderer.render(model: vm, fonts: loadFonts(), theme: theme);

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(5000));
    // Sanity on the composed model.
    expect(vm.summary.tiles.first.value, contains('12,400.00'));
    expect(vm.category.rows.any((r) => r.label == 'أخرى'), isTrue); // "Other"
    File('build/report_full_ar.pdf').writeAsBytesSync(bytes);
    expect(vm.appendix, isNotEmpty); // includeTransactionDetails → appendix
    // Per-page PDFs for single-page rasterization/inspection.
    for (var i = 0; i < 7; i++) {
      final page = await renderer.renderSinglePage(
          model: vm, fonts: loadFonts(), theme: theme, index: i);
      File('build/report_ar_p$i.pdf').writeAsBytesSync(page);
    }
  });

  test('privacy mode masks amounts but keeps insights and structure', () async {
    final snap = await builder.build(
      const ReportRequest(period: MonthlyPeriod(), privacyMode: true),
    );
    final vm = composer.compose(snap);
    expect(vm.summary.tiles.first.value, '••••'); // income tile masked
    expect(vm.cashFlow.first.income, '••••');
    expect(vm.category.rows.first.value, '••••');
    expect(vm.insights, isNotEmpty); // insights still computed
    // Rendering must still succeed.
    final bytes =
        await renderer.render(model: vm, fonts: loadFonts(), theme: theme);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('renders a full English report PDF from real data', () async {
    final snap = await snapshotFor('en');
    final vm = composer.compose(snap);
    final bytes =
        await renderer.render(model: vm, fonts: loadFonts(), theme: theme);

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(vm.comparison.firstWhere((r) => r.metric == 'Expenses').delta,
        contains('11.9%'));
    expect(vm.category.rows.any((r) => r.label == 'Groceries'), isTrue);
    File('build/report_full_en.pdf').writeAsBytesSync(bytes);
  });
}
