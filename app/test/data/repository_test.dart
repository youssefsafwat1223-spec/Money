import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/utils/id_generator.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
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
  late DriftMerchantCategoryRepository merchantCategoryRepository;
  late DriftBudgetRepository budgetRepository;
  late DriftGoalRepository goalRepository;
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
    merchantCategoryRepository = DriftMerchantCategoryRepository(db);
    budgetRepository = DriftBudgetRepository(db);
    goalRepository = DriftGoalRepository(db);
    addTransaction = AddTransactionUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
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

  test('first launch seeds categories, merchant mappings, and suggested goals',
      () async {
    expect(await db.count('categories'), 21);
    final allExpensesCategory = await db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(BudgetEntity.allExpensesCategoryKey)],
    ).getSingleOrNull();
    expect(allExpensesCategory?.read<String>('id'), BudgetEntity.allExpensesCategoryId);
    expect(await db.count('merchant_category_map'), greaterThan(10));
    expect(await db.count('goals'), 3);
  });

  test(
      'add transaction saves a confirmed transaction and de-duplicates within two minutes',
      () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:BURGER BOUTIQUE\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final firstResult = await addTransaction(rawMessage: rawMessage);
    expect(firstResult.outcome, AddTransactionOutcome.added);
    expect(firstResult.transaction, isNotNull);
    expect(firstResult.transaction!.status, TransactionStatus.confirmed);
    expect(await db.count('transactions'), 1);

    final duplicateResult = await addTransaction(rawMessage: rawMessage);
    expect(duplicateResult.outcome, AddTransactionOutcome.duplicate);
    expect(await db.count('transactions'), 1);
  });

  test('confirm transaction upgrades a pending transaction', () async {
    const rawMessage = 'SAR 20.00';

    final added = await addTransaction(rawMessage: rawMessage);
    expect(added.outcome, AddTransactionOutcome.added);
    expect(added.transaction!.status, TransactionStatus.pending);

    final confirmed = await confirmTransaction(added.transaction!.id);
    expect(confirmed.status, TransactionStatus.confirmed);
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
      alert80Sent: false,
      alert100Sent: false,
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
    final goal = GoalEntity(
      id: IdGenerator.next(),
      name: 'جهاز جديد',
      targetAmount: 4000,
      savedAmount: 500,
      deadline: DateTime.utc(2026, 12, 1),
      vaultSkin: 'tech_goal',
      status: 'active',
      createdAt: DateTime.utc(2026, 6, 1),
    );

    final savedGoal = await saveGoal(goal);
    expect(savedGoal.name, 'جهاز جديد');

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

    await deleteGoal(savedGoal.id);
    expect(await goalRepository.getById(savedGoal.id), isNull);
  });
}
