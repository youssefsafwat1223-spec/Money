import 'dart:convert';

import '../../../core/sync/conflict_policy.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../../domain/finance/money_transport.dart';
import '../../../domain/entities/card_entity.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/category_entity.dart';
import '../../../domain/entities/goal_entity.dart';
import '../../../domain/entities/plan_entity.dart';
import '../../../domain/entities/supporting_entities.dart';

enum PlanningSyncOperation { create, update, delete }

/// مفتاح تفعيل الجيل الثاني من مزامنة البطاقات (حساب اختياري + تصميم مخصّص).
///
/// خامل الآن (`false`): البطاقات بلا حساب تبقى محلية فقط، وحقول التصميم
/// (color_theme/accent_hex) لا تُرسَل — لأن جدول `user_cards` على Supabase ما
/// زال يفرض `local_account_id NOT NULL` ولا يملك عمودَي التصميم.
///
/// للتفعيل: انشر `supabase/migrations/0064_user_cards_optional_account_and_design.sql`
/// ثم اضبط هذا العلم على `true` — عندها تُزامَن البطاقات غير المخصّصة والتصميم.
const bool kUserCardsCloudV2 = false;

class PlanningOutboxItem {
  const PlanningOutboxItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.attemptCount,
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String entityType;
  final String entityId;
  final PlanningSyncOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class PlanningOutboxQueue {
  PlanningOutboxQueue({
    required AppDatabase db,
    required bool Function(String entityType) isSyncEnabled,
    required Future<String?> Function() getAuthUserId,
    void Function()? onQueued,
  })  : _db = db,
        _isSyncEnabled = isSyncEnabled,
        _getAuthUserId = getAuthUserId,
        _onQueued = onQueued;

  static const String accountsEntityType = 'account';
  static const String budgetsEntityType = 'budget';
  static const String subscriptionsEntityType = 'subscription';
  static const String goalsEntityType = 'goal';
  static const String plansEntityType = 'plan';
  static const String cardsEntityType = 'card';
  static const String categoriesEntityType = 'category';
  static const String settingsEntityType = 'settings';
  static const String billPaymentsEntityType = 'bill_payment';
  static const String goalContributionsEntityType = 'goal_contribution';
  static const String planLinksEntityType = 'plan_transaction_link';

  /// MALI-055n — a dedicated default-account command (NOT an account field
  /// mutation). It carries only the target account + an operation id, so a
  /// default switch never rewrites unrelated account fields. Written under a
  /// singleton entity id so successive switches coalesce to the latest target.
  static const String accountDefaultCommandType = 'account_default_command';
  static const String _accountDefaultCommandKey = '__current__';

  /// معرّف محلي ثابت للإعدادات (singleton) — نفسه على كل الأجهزة، فيُصبح صف
  /// user_settings واحدًا لكل مستخدم على الخادم (يلتقي عبر الأجهزة).
  static const String settingsLocalId = 'user_settings';

  final AppDatabase _db;
  final bool Function(String entityType) _isSyncEnabled;
  final Future<String?> Function() _getAuthUserId;
  final void Function()? _onQueued;

  Future<bool> enqueueAccount(
    PlanningSyncOperation op,
    AccountEntity account,
  ) {
    // Route through _enqueue (like every other parent entity) so the payload
    // carries the server_updated_at + server_revision base tokens (MALI-022 /
    // 0068). Previously accounts wrote the outbox directly with NO base token,
    // so the push could only blindly overwrite the remote row.
    return _enqueue(
      entityType: accountsEntityType,
      entityId: account.id,
      op: op,
      table: 'accounts',
      payload: _buildAccountPayload(op, account),
    );
  }

  /// MALI-055n — queue the single default-account command. It rewrites NO
  /// account fields; the push resolves it to the atomic `set_default_account`
  /// server RPC (which demotes the old default + promotes the target in one
  /// transaction). [operationId] gives the command a stable identity for
  /// idempotent replay. Written under a singleton key so switching A→B→C
  /// coalesces to a single command for the latest target.
  Future<bool> enqueueAccountDefault(
    String targetLocalId,
    String operationId,
  ) async {
    if (!_isSyncEnabled(accountsEntityType)) return false;
    if (await _getAuthUserId() == null) return false;
    await _writeOutbox(
      entityType: accountDefaultCommandType,
      entityId: _accountDefaultCommandKey,
      opName: PlanningSyncOperation.update.name,
      payload: {
        'target_local_id': targetLocalId,
        'operation_id': operationId,
      },
      // No local row to flag — the caller has already set is_default locally.
      localUpdateSql: 'UPDATE accounts SET id = id WHERE 1 = 0;',
    );
    return true;
  }

  Future<bool> enqueueBudget(
    PlanningSyncOperation op,
    BudgetEntity budget,
  ) {
    return _enqueue(
      entityType: budgetsEntityType,
      entityId: budget.id,
      op: op,
      table: 'budgets',
      payload: _buildBudgetPayload(op, budget),
    );
  }

  Future<bool> enqueueSubscription(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    return _enqueue(
      entityType: subscriptionsEntityType,
      entityId: bill.id,
      op: op,
      table: 'subscriptions',
      payload: _buildSubscriptionPayload(op, bill),
    );
  }

  Future<bool> enqueueGoal(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    return _enqueue(
      entityType: goalsEntityType,
      entityId: goal.id,
      op: op,
      table: 'goals',
      payload: _buildGoalPayload(op, goal),
    );
  }

  Future<bool> enqueuePlan(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    return _enqueue(
      entityType: plansEntityType,
      entityId: plan.id,
      op: op,
      table: 'plans',
      payload: _buildPlanPayload(op, plan),
    );
  }

  Future<bool> enqueueBillPayment(
    PlanningSyncOperation op,
    BillPaymentEntity payment,
  ) {
    return _enqueue(
      entityType: billPaymentsEntityType,
      entityId: payment.id,
      op: op,
      table: 'bill_payments',
      payload: _withDelete(op, {
        'local_id': payment.id,
        'local_subscription_id': payment.billId,
        'local_transaction_id': payment.transactionId,
        'amount': payment.amount,
        'currency': payment.currency,
        'period_start': payment.periodStart.toUtc().toIso8601String(),
        'period_end': payment.periodEnd.toUtc().toIso8601String(),
        'paid_at': payment.paidAt.toUtc().toIso8601String(),
        'installment_index': payment.installmentIndex,
        'note': payment.note,
      }),
    );
  }

  Future<bool> enqueueGoalContribution(
    PlanningSyncOperation op,
    GoalContributionEntity contribution,
  ) {
    return _enqueue(
      entityType: goalContributionsEntityType,
      entityId: contribution.id,
      op: op,
      table: 'goal_contributions',
      payload: _withDelete(op, {
        'local_id': contribution.id,
        'local_goal_id': contribution.goalId,
        'amount': contribution.amount,
        'created_at': contribution.createdAt.toUtc().toIso8601String(),
        'note': contribution.note,
      }),
    );
  }

  Future<bool> enqueuePlanLink(
    PlanningSyncOperation op, {
    required String planId,
    required String transactionId,
    required DateTime createdAt,
  }) async {
    if (!_isSyncEnabled(planLinksEntityType)) return false;
    if (await _getAuthUserId() == null) return false;
    final entityId = '$planId:$transactionId';
    final payload = _withDelete(op, {
      'local_plan_id': planId,
      'local_transaction_id': transactionId,
      'created_at': createdAt.toUtc().toIso8601String(),
    });
    await _writeOutbox(
      entityType: planLinksEntityType,
      entityId: entityId,
      opName: op.name,
      payload: payload,
      localUpdateSql: "UPDATE plan_transaction_links SET sync_status = 'pending' "
          'WHERE plan_id = ${sqlString(planId)} '
          'AND transaction_id = ${sqlString(transactionId)};',
    );
    return true;
  }

  /// إدراج بطاقة في طابور المزامنة. حارس [kUserCardsCloudV2]: قبل نشر ترقية
  /// Supabase، البطاقات بلا حساب لا تُدرَج (عمود الخادم `local_account_id`
  /// NOT NULL) — تبقى محلية فقط. البطاقات المربوطة بحساب تُزامَن كالمعتاد.
  Future<bool> enqueueCard(
    PlanningSyncOperation op,
    CardEntity card,
  ) {
    if (!kUserCardsCloudV2 && card.accountId == null) {
      return Future.value(false);
    }
    return _enqueue(
      entityType: cardsEntityType,
      entityId: card.id,
      op: op,
      table: 'cards',
      payload: _buildCardPayload(op, card),
    );
  }

  /// إدراج تفضيلات المستخدم (singleton) في طابور المزامنة. تُرسَل الأعمدة
  /// السحابية فقط — لا مفتاح تشفير، لا مسار أفاتار، لا بيانات ملف شخصي.
  Future<bool> enqueueSettings(
    PlanningSyncOperation op,
    UserSettingsEntity settings,
  ) async {
    // Updates are only valid once the local singleton is bound to the server
    // row (server_id attached by the first pull / registration push). Before
    // that, a local settings write is post-wipe reseeded DEFAULTS — automatic
    // writers (e.g. the notification history store) fire within seconds of
    // sign-in, and pushing that update would clobber the user's real cloud
    // settings before the first pull restores them (observed in production:
    // country/currency reset to SA/SAR). Creates stay allowed: the startup
    // registration service is the only creator and it runs AFTER the pull.
    if (op == PlanningSyncOperation.update) {
      final bound = await _db
          .customSelect('SELECT server_id FROM user_settings LIMIT 1;')
          .getSingleOrNull();
      if (bound?.readNullable<String>('server_id') == null) return false;
    }
    return _enqueue(
      entityType: settingsEntityType,
      entityId: settings.id,
      op: op,
      table: 'user_settings',
      payload: _buildSettingsPayload(settings),
    );
  }

  Map<String, dynamic> _buildSettingsPayload(UserSettingsEntity s) {
    return <String, dynamic>{
      'local_id': settingsLocalId,
      // Profile fields sync too (migration 0063) — otherwise the sign-out
      // wipe destroys the user's name/phone/birth date permanently. The
      // avatar stays device-local (it is a file path, not a column).
      'display_name': s.displayName,
      'phone_number': s.phoneNumber,
      'date_of_birth': s.dateOfBirth?.toUtc().toIso8601String(),
      'theme': s.theme,
      'currency': s.currency,
      'language': s.language,
      'country': s.country,
      'input_method': s.inputMethod,
      'notifications_json': s.notificationsJson,
      'privacy_mode_enabled': s.privacyModeEnabled,
      // MALI-059n: consent is device-local + explicit — excluded from the sync
      // payload so it is never transmitted or applied on another device.
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<bool> _enqueue({
    required String entityType,
    required String entityId,
    required PlanningSyncOperation op,
    required String table,
    required Map<String, dynamic> payload,
  }) async {
    if (!_isSyncEnabled(entityType)) return false;
    final userId = await _getAuthUserId();
    if (userId == null) return false;

    // MALI-022: snapshot the last-known server version as an optimistic base
    // token, so the push can detect a concurrent remote edit and conflict
    // instead of blindly overwriting it (mirrors the ledger's server_updated_at
    // token, MALI-009). Null for a never-synced row → the push does a create.
    // MALI-022 / 0068 — snapshot the CAS base revision alongside the timestamp
    // token, so the push can do an atomic compare-and-set when the capability is
    // on. Only revision-CAS entities have a `server_revision` column — append-
    // only children (bill_payment/goal_contribution) do not, so we must not
    // SELECT it for them. A null revision is carried as absent → the push falls
    // back to the guarded timestamp compare, never a blind overwrite.
    final readsRevision = kConflictPolicies[entityType]?.mechanism ==
        ConflictMechanism.revisionCas;
    final cols =
        readsRevision ? 'server_updated_at, server_revision' : 'server_updated_at';
    final baseRow = await _db
        .customSelect(
          'SELECT $cols FROM $table WHERE id = ${sqlString(entityId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final baseToken = baseRow?.readNullable<String>('server_updated_at');
    final baseRevision =
        readsRevision ? baseRow?.readNullable<int>('server_revision') : null;
    final enriched = <String, dynamic>{
      ...payload,
      if (baseToken != null) 'server_updated_at': baseToken,
      if (baseRevision != null) 'server_revision': baseRevision,
    };

    await _writeOutbox(
      entityType: entityType,
      entityId: entityId,
      opName: op.name,
      payload: enriched,
      localUpdateSql:
          "UPDATE $table SET sync_status = 'pending' WHERE id = ${sqlString(entityId)};",
    );
    return true;
  }

  /// MALI-052n: coalescing writer shared by every planning enqueue path — folds
  /// an incoming op into an existing PENDING row for the same (entity_type,
  /// entity_id) so consecutive offline edits become one row (one base token,
  /// no self-conflict), then marks the local row pending.
  Future<void> _writeOutbox({
    required String entityType,
    required String entityId,
    required String opName,
    required Map<String, dynamic> payload,
    required String localUpdateSql,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      final existing = await _db.customSelect(
        'SELECT operation FROM planning_sync_outbox '
        'WHERE entity_type = ${sqlString(entityType)} '
        'AND entity_id = ${sqlString(entityId)} '
        "AND status = 'pending' ORDER BY created_at ASC LIMIT 1;",
      ).getSingleOrNull();
      if (existing != null) {
        final coalesced =
            coalesceOutboxOperation(existing.read<String>('operation'), opName);
        final scope = 'entity_type = ${sqlString(entityType)} '
            'AND entity_id = ${sqlString(entityId)} '
            "AND status = 'pending'";
        if (coalesced == null) {
          await _db.customStatement(
            'DELETE FROM planning_sync_outbox WHERE $scope;',
          );
        } else {
          await _db.customStatement('''
            UPDATE planning_sync_outbox
            SET operation = ${sqlString(coalesced)},
                payload_json = ${sqlString(jsonEncode(payload))},
                attempt_count = 0, status = 'pending', failure_class = NULL,
                last_error = NULL, next_retry_at = NULL,
                updated_at = ${sqlString(now)}
            WHERE $scope;
          ''');
        }
      } else {
        await _db.customStatement('''
          INSERT INTO planning_sync_outbox(
            id, entity_type, entity_id, operation, payload_json,
            attempt_count, status, created_at, updated_at
          ) VALUES (
            ${sqlString(IdGenerator.next())}, ${sqlString(entityType)},
            ${sqlString(entityId)}, ${sqlString(opName)},
            ${sqlString(jsonEncode(payload))}, 0, 'pending',
            ${sqlString(now)}, ${sqlString(now)}
          );
        ''');
      }
      await _db.customStatement(localUpdateSql);
    });
    _onQueued?.call();
  }

  Future<List<PlanningOutboxItem>> pendingItems({
    String? entityType,
    int limit = 50,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final entityClause =
        entityType == null ? '' : 'AND entity_type = ${sqlString(entityType)}';
    final rows = await _db.customSelect('''
      SELECT id, entity_type, entity_id, operation, payload_json,
             attempt_count, last_error, next_retry_at
      FROM planning_sync_outbox
      WHERE status = 'pending'
        AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
        $entityClause
      ORDER BY created_at ASC
      LIMIT $limit;
    ''').get();

    return rows.map((row) {
      final opStr = row.read<String>('operation');
      final op = PlanningSyncOperation.values.firstWhere(
        (e) => e.name == opStr,
        orElse: () => PlanningSyncOperation.update,
      );
      final retryStr = row.readNullable<String>('next_retry_at');
      return PlanningOutboxItem(
        id: row.read<String>('id'),
        entityType: row.read<String>('entity_type'),
        entityId: row.read<String>('entity_id'),
        operation: op,
        payloadJson:
            (jsonDecode(row.read<String>('payload_json')) as Map).cast(),
        attemptCount: row.read<int>('attempt_count'),
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  Future<void> markSuccess(String id) async {
    await _db.customStatement(
      'DELETE FROM planning_sync_outbox WHERE id = ${sqlString(id)};',
    );
  }

  /// MALI-023: typed failure handling — permanent → dead-letter immediately;
  /// retryable → bounded backoff, dead-letter after [kOutboxMaxAttempts].
  Future<void> markFailed(
    String id,
    String error,
    OutboxFailureClass failureClass,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT attempt_count FROM planning_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());

    if (failureClass.isPermanent) {
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET status = 'dead_letter', failure_class = ${sqlString(failureClass.name)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final attempts = row.read<int>('attempt_count') + 1;
    if (attempts >= kOutboxMaxAttempts) {
      await _db.customStatement('''
        UPDATE planning_sync_outbox
        SET status = 'dead_letter', attempt_count = $attempts,
            failure_class = ${sqlString(failureClass.name)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: _backoff(attempts))),
    );
    await _db.customStatement('''
      UPDATE planning_sync_outbox
      SET attempt_count = $attempts, failure_class = ${sqlString(failureClass.name)},
          last_error = ${sqlString(error)}, next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// MALI-023: re-arm dead-lettered rows (e.g. after an app/schema upgrade).
  Future<int> reArmDeadLetter() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE planning_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE status = 'dead_letter';
    ''');
  }

  Future<int> deadLetterCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM planning_sync_outbox WHERE status = 'dead_letter';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildAccountPayload(
    PlanningSyncOperation op,
    AccountEntity account,
  ) {
    final payload = <String, dynamic>{
      'local_id': account.id,
      'name': account.name,
      'currency': account.currency,
      'type': account.type.name,
      'initial_balance': moneyToLegacyJsonNumberOrNull(account.initialBalanceMoney),
      'current_balance': moneyToLegacyJsonNumberOrNull(account.currentBalanceMoney),
      'bank_account_number': account.bankAccountNumber,
      'credit_limit': moneyToLegacyJsonNumberOrNull(account.creditLimitMoney),
      'available_credit': moneyToLegacyJsonNumberOrNull(account.availableCreditMoney),
      'payment_due_day': account.paymentDueDay,
      'wallet_provider': account.walletProvider,
      'exclude_from_totals': account.excludeFromTotals,
      'metadata': account.metadata ?? const <String, dynamic>{},
      'is_default': account.isDefault,
      'sort_order': account.sortOrder,
      'created_at': account.createdAt.toUtc().toIso8601String(),
      'updated_at': account.updatedAt.toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Future<bool> enqueueCategory(
    PlanningSyncOperation op,
    CategoryEntity category,
  ) {
    return _enqueue(
      entityType: categoriesEntityType,
      entityId: category.id,
      op: op,
      table: 'categories',
      payload: _buildCategoryPayload(op, category),
    );
  }

  Map<String, dynamic> _buildCategoryPayload(
    PlanningSyncOperation op,
    CategoryEntity category,
  ) {
    final payload = <String, dynamic>{
      'local_id': category.id,
      'key': category.key,
      'name_ar': category.nameAr,
      'icon': category.icon,
      'color': category.color,
      'is_income': category.isIncome,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _buildCardPayload(
    PlanningSyncOperation op,
    CardEntity card,
  ) {
    final payload = <String, dynamic>{
      'local_id': card.id,
      'local_account_id': card.accountId,
      'nickname': card.nickname,
      'last4': card.last4,
      'network': card.network.name,
      'source': card.source.name,
      'color_theme': card.colorTheme,
      'accent_hex': card.accentHex,
      'created_at': card.createdAt.toUtc().toIso8601String(),
      'updated_at': card.updatedAt.toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _withDelete(
    PlanningSyncOperation op,
    Map<String, dynamic> payload,
  ) {
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _buildBudgetPayload(
    PlanningSyncOperation op,
    BudgetEntity budget,
  ) {
    return _withDelete(op, {
      'local_id': budget.id,
      'category_id': budget.categoryId,
      'amount': budget.amount,
      'period': budget.period.name,
      'start_date': budget.startDate.toUtc().toIso8601String(),
      'is_active': budget.isActive,
      'last_notified_spent_amount': budget.lastNotifiedSpentAmount,
      'last_notified_period_start':
          budget.lastNotifiedPeriodStart.toUtc().toIso8601String(),
      'show_on_header': budget.showOnHeader,
      'local_account_id': budget.accountId,
    });
  }

  Map<String, dynamic> _buildSubscriptionPayload(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    return _withDelete(op, {
      'local_id': bill.id,
      'local_account_id': bill.accountId,
      'merchant_id': bill.merchantId,
      'name': bill.name,
      'amount': bill.amount,
      'currency': bill.currency,
      'type': bill.type.name,
      'frequency': bill.frequency.name,
      'next_due_date': bill.nextDueDate.toUtc().toIso8601String(),
      'reminder_on': bill.reminderOn,
      'is_confirmed': bill.isConfirmed,
      'custom_interval_days': bill.customIntervalDays,
      'note': bill.note,
      'status': bill.status.name,
      'total_installments': bill.totalInstallments,
      'paid_count': bill.paidCount,
      'manual_paid_amount': bill.manualPaidAmount,
      'total_purchase_amount': bill.totalPurchaseAmount,
      'lender_name': bill.lenderName,
      'interest_rate': bill.interestRate,
      'created_at': bill.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildGoalPayload(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    return _withDelete(op, {
      'local_id': goal.id,
      'local_account_id': goal.accountId,
      'name': goal.name,
      'target_amount': goal.targetAmount,
      'saved_amount': goal.savedAmount,
      'deadline': goal.deadline?.toUtc().toIso8601String(),
      'vault_skin': goal.vaultSkin,
      'status': goal.status,
      'auto_save_amount': goal.autoSaveAmount,
      'auto_save_period': goal.autoSavePeriod,
      'auto_save_last_run': goal.autoSaveLastRun?.toUtc().toIso8601String(),
      'last_notified_saved_amount': goal.lastNotifiedSavedAmount,
      'created_at': goal.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildPlanPayload(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    return _withDelete(op, {
      'local_id': plan.id,
      'name': plan.name,
      'budget_amount': moneyToLegacyJsonNumber(plan.budgetAmountMoney),
      'currency': plan.currency,
      'start_date': plan.startDate.toUtc().toIso8601String(),
      'end_date': plan.endDate.toUtc().toIso8601String(),
      'local_account_ids': plan.accountIds,
      'card_last4s': plan.cardLast4s,
      'status': plan.status.name,
      'icon': plan.icon,
      'created_at': plan.createdAt.toUtc().toIso8601String(),
    });
  }
}
