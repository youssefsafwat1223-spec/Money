import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/utils/id_generator.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/domain/usecases/save_budget_usecase.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository transactionRepository;
  late DriftAccountRepository accountRepository;
  late DriftMerchantCategoryRepository merchantCategoryRepository;
  late DriftBudgetRepository budgetRepository;
  late DriftBillRepository billRepository;
  late DriftGoalRepository goalRepository;
  late DriftUserSettingsRepository userSettingsRepository;
  late AddTransactionUseCase addTransaction;
  late ConfirmTransactionUseCase confirmTransaction;
  late CorrectCategoryUseCase correctCategory;
  late SaveBudgetUseCase saveBudget;
  late DeleteBudgetUseCase deleteBudget;
  late SaveGoalUseCase saveGoal;
  late DeleteGoalUseCase deleteGoal;
  late AddGoalContributionUseCase addGoalContribution;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    transactionRepository = DriftTransactionRepository(db);
    accountRepository = DriftAccountRepository(db);
    merchantCategoryRepository = DriftMerchantCategoryRepository(db);
    budgetRepository = DriftBudgetRepository(db);
    billRepository = DriftBillRepository(db);
    goalRepository = DriftGoalRepository(db);
    userSettingsRepository = DriftUserSettingsRepository(db);
    addTransaction = AddTransactionUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
    );
    confirmTransaction = ConfirmTransactionUseCase(transactionRepository);
    correctCategory = CorrectCategoryUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
    );
    saveBudget = SaveBudgetUseCase(budgetRepository);
    deleteBudget = DeleteBudgetUseCase(budgetRepository);
    saveGoal = SaveGoalUseCase(goalRepository);
    deleteGoal = DeleteGoalUseCase(goalRepository);
    addGoalContribution = AddGoalContributionUseCase(goalRepository);
  });

  tearDown(() async {
    await db.close();
  });

  test('first launch seeds categories and merchant mappings only', () async {
    // 25 product categories + 1 internal "all expenses".
    expect(await db.count('categories'), 26);
    final allExpensesCategory = await db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(BudgetEntity.allExpensesCategoryKey)],
    ).getSingleOrNull();
    expect(allExpensesCategory?.read<String>('id'),
        BudgetEntity.allExpensesCategoryId);
    expect(await db.count('merchant_category_map'), greaterThan(10));
    expect(await db.count('goals'), 0);
    final userVersion =
        await db.customSelect('PRAGMA user_version;').getSingle();
    expect(userVersion.read<int>('user_version'), db.schemaVersion);
  });

  test('repairs stale and future bank capture timestamps on initialize',
      () async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at,
          comparison_timestamp, comparison_timestamp_source,
          transaction_time_from_sms
        ) VALUES (?, 1, 'EGP', 'payment', 'bank', ?, 'old stale capture',
          0.9, 'confirmed', ?, ?, ?, 'sms_body', ?);
      ''',
      variables: [
        Variable.withString('tx_stale_sms_body'),
        Variable.withString('2024-07-05T08:26:00.000Z'),
        Variable.withString('2026-07-05T09:16:00.000Z'),
        Variable.withString('2026-07-05T09:16:00.000Z'),
        Variable.withString('2024-07-05T08:26:00.000Z'),
        Variable.withString('2024-07-05T08:26:00.000Z'),
      ],
    );
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at,
          comparison_timestamp, comparison_timestamp_source,
          transaction_time_from_sms
        ) VALUES (?, 1, 'EGP', 'payment', 'bank', ?, 'future capture',
          0.9, 'confirmed', ?, ?, ?, 'sms_body', ?);
      ''',
      variables: [
        Variable.withString('tx_future_sms_body'),
        Variable.withString('2026-07-05T11:26:00.000Z'),
        Variable.withString('2026-07-05T09:16:00.000Z'),
        Variable.withString('2026-07-05T09:16:00.000Z'),
        Variable.withString('2026-07-05T11:26:00.000Z'),
        Variable.withString('2026-07-05T11:26:00.000Z'),
      ],
    );

    // MALI-027: initialize() is memoized per instance (no double-migration), so
    // re-running the idempotent startup repairs on freshly-inserted stale data
    // uses the explicit re-run seam.
    await db.debugReinitialize();

    final rows = await db.customSelect(
      '''
        SELECT id, occurred_at, sms_received_at, comparison_timestamp,
               comparison_timestamp_source, transaction_time_from_sms
        FROM transactions
        WHERE id IN (?, ?)
        ORDER BY id;
      ''',
      variables: [
        Variable.withString('tx_future_sms_body'),
        Variable.withString('tx_stale_sms_body'),
      ],
    ).get();

    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.read<String>('occurred_at'), '2026-07-05T09:16:00.000Z');
      expect(row.read<String>('sms_received_at'), '2026-07-05T09:16:00.000Z');
      expect(
          row.read<String>('comparison_timestamp'), '2026-07-05T09:16:00.000Z');
      expect(row.read<String>('comparison_timestamp_source'), 'received_at');
      expect(row.readNullable<String>('transaction_time_from_sms'), isNull);
    }
  });

  test('account-scoped reads EXCLUDE null-account rows; global scope includes '
      'them (MALI-074n exact ownership)', () async {
    final account = await accountRepository.getDefault();
    expect(account, isNotNull);
    final now = DateTime.utc(2026, 7, 5, 9, 30);
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at
        ) VALUES (?, 12.5, ?, 'payment', 'bank', ?, 'legacy same currency',
          0.9, 'confirmed', ?, ?);
      ''',
      variables: [
        Variable.withString('legacy_same_currency'),
        Variable.withString(account!.currency),
        Variable.withString(now.toIso8601String()),
        Variable.withString(now.toIso8601String()),
        Variable.withString(now.toIso8601String()),
      ],
    );
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at
        ) VALUES (?, 99, 'EGP', 'payment', 'bank', ?, 'legacy other currency',
          0.9, 'confirmed', ?, ?);
      ''',
      variables: [
        Variable.withString('legacy_other_currency'),
        Variable.withString(now.toIso8601String()),
        Variable.withString(now.toIso8601String()),
        Variable.withString(now.toIso8601String()),
      ],
    );

    final total = await transactionRepository.expenseTotalBetween(
      from: now.subtract(const Duration(minutes: 1)),
      to: now.add(const Duration(minutes: 1)),
      accountId: account.id,
    );
    final recent =
        await transactionRepository.getRecent(limit: 10, accountId: account.id);
    final globalRecent =
        await transactionRepository.getRecent(limit: 10, accountId: null);

    // Exact ownership: an unassigned row is NOT attributed to a specific
    // account just because its currency matches.
    expect(total, 0);
    expect(recent.map((tx) => tx.id), isNot(contains('legacy_same_currency')));
    expect(recent.map((tx) => tx.id), isNot(contains('legacy_other_currency')));
    // All-accounts scope surfaces unassigned rows (both currencies).
    expect(globalRecent.map((tx) => tx.id), contains('legacy_same_currency'));
    expect(globalRecent.map((tx) => tx.id), contains('legacy_other_currency'));
  });

  test('editing transaction time updates duplicate comparison time', () async {
    final originalAt = DateTime.utc(2026, 7, 13, 12, 30);
    final editedAt = DateTime.utc(2026, 7, 13, 13);
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at,
          comparison_timestamp, comparison_timestamp_source
        ) VALUES (?, 25, 'EGP', 'payment', 'unknown', ?, 'QA edit',
          1, 'confirmed', ?, ?, ?, 'received_at');
      ''',
      variables: [
        Variable.withString('tx_edit_time'),
        Variable.withString(originalAt.toIso8601String()),
        Variable.withString(originalAt.toIso8601String()),
        Variable.withString(originalAt.toIso8601String()),
        Variable.withString(originalAt.toIso8601String()),
      ],
    );

    await transactionRepository.updateTransaction(
      transactionId: 'tx_edit_time',
      amount: Money.fromLegacyReal(25, 'EGP'),
      currency: 'EGP',
      type: TransactionTypeEntity.payment,
      occurredAt: editedAt,
      rawMerchant: 'QA edit',
      categoryId: null,
      note: null,
    );

    final row = await db.customSelect(
      '''
        SELECT occurred_at, comparison_timestamp
        FROM transactions WHERE id = ?;
      ''',
      variables: [Variable.withString('tx_edit_time')],
    ).getSingle();
    expect(row.read<String>('occurred_at'), editedAt.toIso8601String());
    expect(
      row.read<String>('comparison_timestamp'),
      editedAt.toIso8601String(),
    );
  });

  test(
      'saving with a missing seeded category recreates it instead of falling back to other',
      () async {
    await db.customStatement("DELETE FROM categories WHERE key = 'transfers';");
    expect(
      await db
          .customSelect("SELECT id FROM categories WHERE key = 'transfers';")
          .getSingleOrNull(),
      isNull,
    );

    final now = DateTime.utc(2026, 6, 27, 10, 0);
    final saved = await transactionRepository.saveTransaction(
      transaction: TransactionEntity(
        id: IdGenerator.next(),
        amountMoney: Money.fromLegacyReal(31.43, 'EGP'),
        currency: 'EGP',
        type: TransactionTypeEntity.transfer,
        source: TransactionSourceEntity.aiParsed,
        occurredAt: now,
        rawMessage: 'IPN transfer sent with amount of EGP 31.43',
        parseConfidence: 0.79,
        status: TransactionStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
      categoryKey: 'transfers',
    );

    expect(saved.categoryId, isNotNull);
    final categoryLookup = await db.customSelect(
      '''
        SELECT categories.key AS category_key
        FROM transactions
        INNER JOIN categories ON categories.id = transactions.category_id
        WHERE transactions.id = ?;
      ''',
      variables: [Variable.withString(saved.id)],
    ).getSingle();
    expect(categoryLookup.read<String>('category_key'), 'transfers');
  });

  test('transaction pages are ordered and non-overlapping', () async {
    for (var i = 0; i < 7; i++) {
      final now = DateTime.utc(2026, 7, 14, 12, i);
      await transactionRepository.saveTransaction(
        transaction: TransactionEntity(
          id: 'paged-$i',
          amountMoney: Money.fromLegacyReal(i + 1, 'SAR'),
          currency: 'SAR',
          type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.unknown,
          occurredAt: now,
          rawMessage: '',
          parseConfidence: 1,
          status: TransactionStatus.confirmed,
          createdAt: now,
          updatedAt: now,
        ),
        categoryKey: 'other',
      );
    }

    final first = await transactionRepository.getPage(offset: 0, limit: 3);
    final second = await transactionRepository.getPage(offset: 3, limit: 3);
    final third = await transactionRepository.getPage(offset: 6, limit: 3);

    expect(first.map((tx) => tx.id), ['paged-6', 'paged-5', 'paged-4']);
    expect(second.map((tx) => tx.id), ['paged-3', 'paged-2', 'paged-1']);
    expect(third.map((tx) => tx.id), ['paged-0']);
  });

  test('saving transfer with other category is normalized to transfers',
      () async {
    final now = DateTime.utc(2026, 6, 27, 10, 15);
    final saved = await transactionRepository.saveTransaction(
      transaction: TransactionEntity(
        id: IdGenerator.next(),
        amountMoney: Money.fromLegacyReal(250, 'EGP'),
        currency: 'EGP',
        type: TransactionTypeEntity.transfer,
        source: TransactionSourceEntity.aiParsed,
        rawMerchant: 'Ahmed Hassan',
        occurredAt: now,
        rawMessage: 'Transfer sent with amount of EGP 250.00 to Ahmed Hassan',
        parseConfidence: 0.79,
        status: TransactionStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
      categoryKey: 'other',
    );

    final lookup = await db.customSelect(
      '''
        SELECT categories.key AS category_key, transactions.raw_merchant AS raw_merchant
        FROM transactions
        INNER JOIN categories ON categories.id = transactions.category_id
        WHERE transactions.id = ?;
      ''',
      variables: [Variable.withString(saved.id)],
    ).getSingle();

    expect(lookup.read<String>('category_key'), 'transfers');
    expect(lookup.readNullable<String>('raw_merchant'), isNull);
  });

  test(
      'startup backfills old wrong transfer categories and clears person names',
      () async {
    final now = DateTime.utc(2026, 6, 27, 10, 30);
    final txId = IdGenerator.next();
    final otherCategory = await db
        .customSelect("SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
        .getSingle();
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, category_id, type, source, raw_merchant,
          occurred_at, raw_message, parse_confidence, status, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(txId),
        Variable.withReal(31.43),
        Variable.withString('EGP'),
        Variable.withString(otherCategory.read<String>('id')),
        Variable.withString('transfer'),
        Variable.withString('aiParsed'),
        Variable.withString('Ahmed Hassan'),
        Variable.withString(now.toUtc().toIso8601String()),
        Variable.withString('old transfer saved as other'),
        Variable.withReal(0.79),
        Variable.withString('pending'),
        Variable.withString(now.toUtc().toIso8601String()),
        Variable.withString(now.toUtc().toIso8601String()),
      ],
    );

    // MALI-027: re-run seam (initialize() is memoized; see note above).
    await db.debugReinitialize();

    final categoryLookup = await db.customSelect(
      '''
        SELECT categories.key AS category_key, transactions.raw_merchant AS raw_merchant
        FROM transactions
        INNER JOIN categories ON categories.id = transactions.category_id
        WHERE transactions.id = ?;
      ''',
      variables: [Variable.withString(txId)],
    ).getSingle();
    expect(categoryLookup.read<String>('category_key'), 'transfers');
    expect(categoryLookup.readNullable<String>('raw_merchant'), isNull);
  });

  test('startup backfills old credited transfer direction', () async {
    final now = DateTime.utc(2026, 6, 27, 13, 29);
    final txId = IdGenerator.next();
    final transferCategory = await db
        .customSelect(
            "SELECT id FROM categories WHERE key = 'transfers' LIMIT 1;")
        .getSingle();
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, category_id, type, source,
          occurred_at, raw_message, parse_confidence, status, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(txId),
        Variable.withReal(9000),
        Variable.withString('EGP'),
        Variable.withString(transferCategory.read<String>('id')),
        Variable.withString('transfer'),
        Variable.withString('aiParsed'),
        Variable.withString(now.toUtc().toIso8601String()),
        Variable.withString(
            'تم إضافة تحويل لحظي لبطاقتكم مسبقة الدفع بمبلغ 9000.00 جم'),
        Variable.withReal(0.79),
        Variable.withString('pending'),
        Variable.withString(now.toUtc().toIso8601String()),
        Variable.withString(now.toUtc().toIso8601String()),
      ],
    );

    // MALI-027: re-run seam (initialize() is memoized; see note above).
    await db.debugReinitialize();

    final row = await db.customSelect(
      'SELECT direction FROM transactions WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(txId)],
    ).getSingle();
    expect(row.read<String>('direction'), 'credit');
  });

  test('user profile settings persist editable identity fields', () async {
    final settings = await userSettingsRepository.getSettings();

    await userSettingsRepository.saveSettings(
      settings.copyWith(
        displayName: 'يوسف',
        phoneNumber: '+201001112223',
        avatarPath: '/tmp/profile-avatar.jpg',
      ),
    );

    final updated = await userSettingsRepository.getSettings();
    expect(updated.displayName, 'يوسف');
    expect(updated.phoneNumber, '+201001112223');
    expect(updated.avatarPath, '/tmp/profile-avatar.jpg');
    expect(updated.country, settings.country);
    expect(updated.currency, settings.currency);
  });

  test('new merchant stays pending and exact duplicate goes to Smart Inbox',
      () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:BURGER BOUTIQUE\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final firstResult = await addTransaction(rawMessage: rawMessage);
    expect(firstResult.outcome, AddTransactionOutcome.added);
    expect(firstResult.transaction, isNotNull);
    expect(firstResult.transaction!.status, TransactionStatus.pending);
    expect(firstResult.requiresConfirmation, isTrue);
    expect(await db.count('transactions'), 1);

    final duplicateResult = await addTransaction(rawMessage: rawMessage);
    expect(duplicateResult.outcome, AddTransactionOutcome.suspiciousDuplicate);
    expect(await db.count('transactions'), 1);
    expect(await db.count('suspected_duplicates'), 1);
  });

  test('trusted sender and known merchant can auto-confirm', () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final result =
        await addTransaction(rawMessage: rawMessage, senderId: 'SNB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction!.status, TransactionStatus.confirmed);
    expect(result.requiresConfirmation, isFalse);
  });

  test('confirm transaction upgrades a pending transaction', () async {
    const rawMessage = 'Purchase SAR 20.00 At UNKNOWN SHOP';

    final added = await addTransaction(rawMessage: rawMessage);
    expect(added.outcome, AddTransactionOutcome.added);
    expect(added.transaction!.status, TransactionStatus.pending);

    final confirmed = await confirmTransaction(added.transaction!.id);
    expect(confirmed.status, TransactionStatus.confirmed);
  });

  test('confirming an unknown-type transaction grounds it by direction',
      () async {
    final now = DateTime.utc(2026, 4, 8, 12);
    final saved = await transactionRepository.saveTransaction(
      transaction: TransactionEntity(
        id: 'tx-unknown-debit',
        amountMoney: Money.fromLegacyReal(30, 'SAR'),
        currency: 'SAR',
        type: TransactionTypeEntity.unknown,
        source: TransactionSourceEntity.bank,
        occurredAt: now,
        rawMessage: 'msg',
        parseConfidence: 0.6,
        status: TransactionStatus.pending,
        createdAt: now,
        updatedAt: now,
        direction: TransactionDirectionEntity.debit,
      ),
      categoryKey: null,
    );

    final confirmed = await transactionRepository.confirm(saved.id);

    // Confirmed transactions must land in a totals bucket, never 'unknown'.
    expect(confirmed.type, TransactionTypeEntity.payment);
    final total = await transactionRepository.expenseTotalBetween(
      from: DateTime.utc(2026, 4, 1),
      to: DateTime.utc(2026, 5, 1),
    );
    expect(total, 30);
  });

  test('pending transactions are excluded from financial totals', () async {
    const rawMessage = 'Purchase SAR 20.00 At UNKNOWN SHOP 2026-04-08 12:00';

    final added = await addTransaction(rawMessage: rawMessage);
    expect(added.transaction!.status, TransactionStatus.pending);

    final beforeConfirm = await transactionRepository.expenseTotalBetween(
      from: DateTime.utc(2026, 4, 1),
      to: DateTime.utc(2026, 5, 1),
    );
    expect(beforeConfirm, 0);

    await confirmTransaction(added.transaction!.id);
    final afterConfirm = await transactionRepository.expenseTotalBetween(
      from: DateTime.utc(2026, 4, 1),
      to: DateTime.utc(2026, 5, 1),
    );
    expect(afterConfirm, 20);
  });

  test(
      'correct category applies to one transaction or all future merchant transactions',
      () async {
    const rawMessage =
        'عملية شراء\nمبلغ:SAR 18.00\nلدى:BURGER LAB\nفي:2026-04-08 18:30';

    final firstAdded = await addTransaction(rawMessage: rawMessage);
    final correctedThisOnly = await correctCategory(
      transactionId: firstAdded.transaction!.id,
      categoryKey: 'cafes',
      scope: CategoryCorrectionScope.thisTransactionOnly,
    );
    expect(correctedThisOnly.categoryId, isNotNull);

    const secondRawMessage =
        'عملية شراء\nمبلغ:SAR 22.00\nلدى:BURGER LAB\nفي:2026-04-08 19:10';
    final secondAdded = await addTransaction(rawMessage: secondRawMessage);

    await correctCategory(
      transactionId: secondAdded.transaction!.id,
      categoryKey: 'cafes',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    const thirdRawMessage =
        'عملية شراء\nمبلغ:SAR 24.00\nلدى:BURGER LAB\nفي:2026-04-08 20:10';
    final thirdAdded = await addTransaction(rawMessage: thirdRawMessage);
    final thirdStored =
        await transactionRepository.getById(thirdAdded.transaction!.id);

    expect(thirdStored?.categoryId, isNotNull);
    final categoryLookup = await db.customSelect(
      '''
        SELECT categories.key AS category_key
        FROM transactions
        INNER JOIN categories ON categories.id = transactions.category_id
        WHERE transactions.id = ?;
      ''',
      variables: [Variable.withString(thirdAdded.transaction!.id)],
    ).getSingle();
    expect(categoryLookup.read<String>('category_key'), 'cafes');
  });

  test('budget CRUD persists records', () async {
    final groceriesCategory = await db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString('groceries')],
    ).getSingle();

    final budget = BudgetEntity(
      id: IdGenerator.next(),
      categoryId: groceriesCategory.read<String>('id'),
      amount: 1200,
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 6, 1),
      isActive: true,
      lastNotifiedSpentAmount: 0.0,
      lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
    );

    final saved = await saveBudget(budget);
    expect(saved.amount, 1200);

    final updated = await saveBudget(saved.copyWith(amount: 1400));
    expect(updated.amount, 1400);

    final fetched = await budgetRepository.getById(saved.id);
    expect(fetched?.amount, 1400);

    await deleteBudget(saved.id);
    expect(await budgetRepository.getById(saved.id), isNull);
  });

  test('goal CRUD and contributions update saved amount', () async {
    final defaultAccount = await accountRepository.getDefault();
    final goal = GoalEntity(
      id: IdGenerator.next(),
      name: 'جهاز جديد',
      accountId: defaultAccount?.id,
      targetAmount: 4000,
      savedAmount: 500,
      deadline: DateTime.utc(2026, 12, 1),
      vaultSkin: 'tech_goal',
      status: 'active',
      createdAt: DateTime.utc(2026, 6, 1),
    );

    final savedGoal = await saveGoal(goal);
    expect(savedGoal.name, 'جهاز جديد');
    expect(savedGoal.accountId, defaultAccount?.id);

    await addGoalContribution(
      GoalContributionEntity(
        id: IdGenerator.next(),
        goalId: savedGoal.id,
        amount: 300,
        createdAt: DateTime.utc(2026, 6, 2),
        note: 'دفعة أولى',
      ),
    );

    final updatedGoal = await goalRepository.getById(savedGoal.id);
    expect(updatedGoal?.savedAmount, 800);
    expect(updatedGoal?.accountId, defaultAccount?.id);

    await deleteGoal(savedGoal.id);
    expect(await goalRepository.getById(savedGoal.id), isNull);
  });

  test(
      'bill CRUD supports subscriptions, installments, reminders, and due range',
      () async {
    final subscription = BillEntity(
      id: IdGenerator.next(),
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(49, 'SAR'),
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 6, 15),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 6, 1),
    );
    final installment = BillEntity(
      id: IdGenerator.next(),
      name: 'قسط جوال',
      amountMoney: Money.fromLegacyReal(250, 'SAR'),
      currency: 'SAR',
      type: BillType.installment,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 7, 1),
      reminderOn: false,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 6, 1),
      manualPaidMoney: Money.fromLegacyReal(500, 'SAR'),
    );

    final savedSubscription = await billRepository.save(subscription);
    final savedInstallment = await billRepository.save(installment);
    expect(savedSubscription.type, BillType.subscription);
    expect(savedInstallment.type, BillType.installment);
    expect(savedInstallment.manualPaidAmount, 500);

    final payment = await billRepository.recordPayment(
      BillPaymentEntity(
        id: IdGenerator.next(),
        billId: savedInstallment.id,
        amountMoney: Money.fromLegacyReal(250, 'SAR'),
        currency: 'SAR',
        periodStart: DateTime.utc(2026, 7, 1),
        periodEnd: DateTime.utc(2026, 7, 31),
        paidAt: DateTime.utc(2026, 7, 2),
        installmentIndex: 1,
        note: 'دفعة يوليو',
      ),
    );
    expect(payment.amount, 250);
    final payments = await billRepository.getPayments(savedInstallment.id);
    expect(payments.map((item) => item.id), contains(payment.id));
    final installmentAfterPayment =
        await billRepository.getById(savedInstallment.id);
    expect(installmentAfterPayment?.paidCount, 1);

    final updated = await billRepository.save(
      savedSubscription.copyWith(
        frequency: BillFrequency.yearly,
        reminderOn: false,
      ),
    );
    expect(updated.frequency, BillFrequency.yearly);
    expect(updated.reminderOn, isFalse);

    final juneBills = await billRepository.getDueBetween(
      from: DateTime.utc(2026, 6, 1),
      to: DateTime.utc(2026, 6, 30),
    );
    expect(juneBills.map((bill) => bill.id), contains(savedSubscription.id));
    expect(
        juneBills.map((bill) => bill.id), isNot(contains(savedInstallment.id)));

    await billRepository.delete(savedSubscription.id);
    expect(await billRepository.getById(savedSubscription.id), isNull);
  });
}
