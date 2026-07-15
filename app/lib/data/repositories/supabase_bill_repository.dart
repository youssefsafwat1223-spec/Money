import 'package:postgrest/postgrest.dart';
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/bill_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'supabase_planning_support.dart';

class SupabaseBillRepository implements BillRepository {
  SupabaseBillRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  }) : _support = SupabasePlanningSupport(
          db: db,
          getClient: getClient,
          getAuthUserId: getAuthUserId,
        );

  final SupabasePlanningSupport _support;

  @override
  Future<List<BillEntity>> getAll() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_subscriptions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('next_due_date');
      return (rows as List)
          .map((row) => _billFromRow(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<List<BillEntity>> getDueBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_subscriptions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .gte('next_due_date', from.toUtc().toIso8601String())
          .lt('next_due_date',
              to.toUtc().add(const Duration(microseconds: 1)).toIso8601String())
          .order('next_due_date');
      return (rows as List)
          .map((row) => _billFromRow(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<BillEntity?> getById(String id) async {
    final uid = await _support.requireUserId();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'subscriptions',
        serverTable: 'user_subscriptions',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) return null;
      final row = await _support
          .client()
          .from('user_subscriptions')
          .select()
          .eq('user_id', uid)
          .eq('id', serverId)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _billFromRow(row);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<BillEntity> save(BillEntity bill) async {
    final uid = await _support.requireUserId();
    final localId = bill.id.isEmpty ? IdGenerator.next() : bill.id;
    final existingServerId = await _support.resolveServerEntityId(
      localTable: 'subscriptions',
      serverTable: 'user_subscriptions',
      userId: uid,
      entityId: bill.id,
    );
    final accountId = await _support.serverAccountId(bill.accountId);
    final payload = {
      'merchant_id': bill.merchantId,
      'name': bill.name,
      'amount': bill.amount,
      'currency': bill.currency.toUpperCase(),
      'type': bill.type.name,
      'frequency': bill.frequency.name,
      'next_due_date': bill.nextDueDate.toUtc().toIso8601String(),
      'reminder_on': bill.reminderOn,
      'is_confirmed': bill.isConfirmed,
      'custom_interval_days': bill.customIntervalDays,
      'note': bill.note,
      'status': bill.status.name,
      'server_account_id': accountId,
      'total_installments': bill.totalInstallments,
      'paid_count': bill.paidCount,
      'manual_paid_amount': bill.manualPaidAmount,
      'total_purchase_amount': bill.totalPurchaseAmount,
      'lender_name': bill.lenderName,
      'interest_rate': bill.interestRate,
      'metadata': <String, dynamic>{},
    };
    Map<String, dynamic>? row;
    var inserted = false;
    try {
      if (existingServerId != null) {
        row = await _support
            .client()
            .from('user_subscriptions')
            .update(payload)
            .eq('user_id', uid)
            .eq('id', existingServerId)
            .select()
            .maybeSingle();
      } else {
        inserted = true;
        row = await _support
            .client()
            .from('user_subscriptions')
            .insert({
              'user_id': uid,
              'local_id': localId,
              'created_at': bill.createdAt.toUtc().toIso8601String(),
              ...payload,
            })
            .select()
            .single();
      }
    } on PostgrestException catch (error) {
      if (error.code != '23505') throw mapSupabaseError(error);
      row = await _support
          .client()
          .from('user_subscriptions')
          .select()
          .eq('user_id', uid)
          .eq('local_id', localId)
          .maybeSingle();
    } catch (error) {
      throw mapSupabaseError(error);
    }
    if (row == null) throw const NotFoundRepoException();
    await mirrorFinancialCacheSafely(
      _support.db,
      subscriptionsCacheEntityType,
      () => _mirrorBill(row!, preferredLocalId: inserted ? localId : null),
    );
    return _billFromRow(row);
  }

  @override
  Future<void> delete(String id) async {
    final uid = await _support.requireUserId();
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'subscriptions',
        serverTable: 'user_subscriptions',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) throw const NotFoundRepoException();
      final row = await _support
          .client()
          .from('user_subscriptions')
          .update({'deleted_at': deletedAt, 'status': 'cancelled'})
          .eq('user_id', uid)
          .eq('id', serverId)
          .select('id')
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await mirrorFinancialCacheSafely(
        _support.db,
        subscriptionsCacheEntityType,
        () => _support.db.customStatement(
          "UPDATE subscriptions SET deleted_at = ?, status = 'cancelled', sync_status = 'synced' WHERE server_id = ?;",
          [deletedAt, serverId],
        ),
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<List<BillPaymentEntity>> getPayments(String billId) async {
    final uid = await _support.requireUserId();
    try {
      final serverBillId = await _support.resolveServerEntityId(
        localTable: 'subscriptions',
        serverTable: 'user_subscriptions',
        userId: uid,
        entityId: billId,
      );
      if (serverBillId == null) return const [];
      final rows = await _support
          .client()
          .from('user_bill_payments')
          .select()
          .eq('user_id', uid)
          .eq('subscription_id', serverBillId)
          .isFilter('deleted_at', null)
          .order('paid_at', ascending: false);
      return (rows as List)
          .map((row) => _paymentFromRow(
                Map<String, dynamic>.from(row as Map),
              ))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) async {
    final uid = await _support.requireUserId();
    final requestId = payment.id.isEmpty ? IdGenerator.next() : payment.id;
    try {
      final serverBillId = await _support.resolveServerEntityId(
        localTable: 'subscriptions',
        serverTable: 'user_subscriptions',
        userId: uid,
        entityId: payment.billId,
      );
      if (serverBillId == null) throw const NotFoundRepoException();
      final serverTransactionId = payment.transactionId == null
          ? null
          : await _support.resolveServerEntityId(
              localTable: 'transactions',
              serverTable: 'user_transactions',
              userId: uid,
              entityId: payment.transactionId,
            );
      if (payment.transactionId != null && serverTransactionId == null) {
        throw const NotFoundRepoException();
      }
      final response = await _support.client().rpc(
        'record_bill_payment',
        params: {
          'p_subscription_id': serverBillId,
          'p_transaction_id': serverTransactionId,
          'p_client_request_id': requestId,
          'p_local_id': requestId,
          'p_amount': payment.amount,
          'p_currency': payment.currency,
          'p_period_start': payment.periodStart.toUtc().toIso8601String(),
          'p_period_end': payment.periodEnd.toUtc().toIso8601String(),
          'p_paid_at': payment.paidAt.toUtc().toIso8601String(),
          'p_installment_index': payment.installmentIndex,
          'p_note': payment.note,
        },
      );
      final result = Map<String, dynamic>.from(response as Map);
      final paymentRow = Map<String, dynamic>.from(result['payment'] as Map);
      final billRow = Map<String, dynamic>.from(result['subscription'] as Map);
      await mirrorFinancialCacheSafely(
        _support.db,
        subscriptionsCacheEntityType,
        () async {
          await _mirrorBill(billRow);
          await _mirrorPayment(paymentRow, preferredLocalId: requestId);
        },
      );
      return _paymentFromRow(paymentRow);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<BillPaymentEntity> createAndRecordPayment({
    required BillEntity bill,
    required BillPaymentEntity payment,
  }) async {
    await _support.requireUserId();
    final billLocalId = bill.id.isEmpty ? IdGenerator.next() : bill.id;
    final paymentRequestId =
        payment.id.isEmpty ? IdGenerator.next() : payment.id;
    final accountId = await _support.serverAccountId(bill.accountId);
    try {
      final response = await _support.client().rpc(
        'create_subscription_and_record_payment',
        params: {
          'p_subscription_local_id': billLocalId,
          'p_payment_client_request_id': paymentRequestId,
          'p_name': bill.name,
          'p_amount': bill.amount,
          'p_currency': bill.currency,
          'p_type': bill.type.name,
          'p_frequency': bill.frequency.name,
          'p_next_due_date': bill.nextDueDate.toUtc().toIso8601String(),
          'p_created_at': bill.createdAt.toUtc().toIso8601String(),
          'p_server_account_id': accountId,
          'p_merchant_id': bill.merchantId,
          'p_reminder_on': bill.reminderOn,
          'p_is_confirmed': bill.isConfirmed,
          'p_custom_interval_days': bill.customIntervalDays,
          'p_note': bill.note,
          'p_status': bill.status.name,
          'p_total_installments': bill.totalInstallments,
          'p_paid_count': bill.paidCount,
          'p_manual_paid_amount': bill.manualPaidAmount,
          'p_total_purchase_amount': bill.totalPurchaseAmount,
          'p_lender_name': bill.lenderName,
          'p_interest_rate': bill.interestRate,
          'p_payment_amount': payment.amount,
          'p_payment_period_start':
              payment.periodStart.toUtc().toIso8601String(),
          'p_payment_period_end': payment.periodEnd.toUtc().toIso8601String(),
          'p_payment_paid_at': payment.paidAt.toUtc().toIso8601String(),
          'p_payment_installment_index': payment.installmentIndex,
          'p_payment_note': payment.note,
        },
      );
      final result = Map<String, dynamic>.from(response as Map);
      final paymentRow = Map<String, dynamic>.from(result['payment'] as Map);
      final billRow = Map<String, dynamic>.from(result['subscription'] as Map);
      await mirrorFinancialCacheSafely(
        _support.db,
        subscriptionsCacheEntityType,
        () async {
          await _mirrorBill(billRow, preferredLocalId: billLocalId);
          await _mirrorPayment(paymentRow, preferredLocalId: paymentRequestId);
        },
      );
      return _paymentFromRow(paymentRow);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) async {
    final uid = await _support.requireUserId();
    try {
      final serverTransactionId = await _support.resolveServerEntityId(
        localTable: 'transactions',
        serverTable: 'user_transactions',
        userId: uid,
        entityId: transactionId,
      );
      if (serverTransactionId == null) return const [];
      final rows = await _support
          .client()
          .from('user_bill_payments')
          .select('id, subscription_id')
          .eq('user_id', uid)
          .eq('transaction_id', serverTransactionId)
          .isFilter('deleted_at', null);
      final billIds = <String>{};
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        billIds.add(row['subscription_id'] as String);
        await deletePayment(row['id'] as String);
      }
      return billIds.toList(growable: false);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<void> deletePayment(String paymentId) async {
    final uid = await _support.requireUserId();
    try {
      final serverPaymentId = await _support.resolveServerEntityId(
        localTable: 'bill_payments',
        serverTable: 'user_bill_payments',
        userId: uid,
        entityId: paymentId,
      );
      if (serverPaymentId == null) throw const NotFoundRepoException();
      final response = await _support.client().rpc(
        'delete_bill_payment',
        params: {'p_payment_id': serverPaymentId},
      );
      final result = Map<String, dynamic>.from(response as Map);
      final payment = Map<String, dynamic>.from(result['payment'] as Map);
      final bill = Map<String, dynamic>.from(result['subscription'] as Map);
      await mirrorFinancialCacheSafely(
        _support.db,
        subscriptionsCacheEntityType,
        () async {
          await _mirrorBill(bill);
          await _support.db.customStatement(
            "UPDATE bill_payments SET deleted_at = ?, sync_status = 'synced' WHERE server_id = ?;",
            [payment['deleted_at'] as String, serverPaymentId],
          );
        },
      );
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<void> repairLocalCache() async {
    final uid = await _support.requireUserId();
    try {
      final bills = await _support.allServerRows('user_subscriptions', uid);
      final payments = await _support.allServerRows('user_bill_payments', uid);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _support.forEachMissingServerRow(
        localTable: 'subscriptions',
        serverIds: bills.map((row) => row['id'] as String).toSet(),
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE subscriptions SET deleted_at = ?, status = 'cancelled', sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in bills) {
        await _mirrorBill(row);
      }
      await _support.forEachMissingServerRow(
        localTable: 'bill_payments',
        serverIds: payments.map((row) => row['id'] as String).toSet(),
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE bill_payments SET deleted_at = ?, sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in payments) {
        await _mirrorPayment(row);
      }
      await clearFinancialCacheDirty(
        _support.db,
        subscriptionsCacheEntityType,
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  BillEntity _billFromRow(Map<String, dynamic> row) {
    return BillEntity(
      id: row['id'] as String,
      merchantId: row['merchant_id'] as String?,
      name: row['name'] as String,
      amount: (row['amount'] as num).toDouble(),
      currency: row['currency'] as String,
      type: BillType.values.firstWhere(
        (value) => value.name == row['type'],
        orElse: () => BillType.subscription,
      ),
      frequency: BillFrequency.values.firstWhere(
        (value) => value.name == row['frequency'],
        orElse: () => BillFrequency.monthly,
      ),
      nextDueDate: DateTime.parse(row['next_due_date'] as String).toUtc(),
      reminderOn: row['reminder_on'] as bool? ?? true,
      isConfirmed: row['is_confirmed'] as bool? ?? false,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      customIntervalDays: row['custom_interval_days'] as int?,
      note: row['note'] as String?,
      status: BillStatus.values.firstWhere(
        (value) => value.name == row['status'],
        orElse: () => BillStatus.active,
      ),
      accountId: row['server_account_id'] as String?,
      totalInstallments: row['total_installments'] as int?,
      paidCount: row['paid_count'] as int?,
      manualPaidAmount: (row['manual_paid_amount'] as num?)?.toDouble(),
      totalPurchaseAmount: (row['total_purchase_amount'] as num?)?.toDouble(),
      lenderName: row['lender_name'] as String?,
      interestRate: (row['interest_rate'] as num?)?.toDouble(),
    );
  }

  BillPaymentEntity _paymentFromRow(Map<String, dynamic> row) {
    return BillPaymentEntity(
      id: row['id'] as String,
      billId: row['subscription_id'] as String,
      amount: (row['amount'] as num).toDouble(),
      currency: row['currency'] as String,
      periodStart: DateTime.parse(row['period_start'] as String).toUtc(),
      periodEnd: DateTime.parse(row['period_end'] as String).toUtc(),
      paidAt: DateTime.parse(row['paid_at'] as String).toUtc(),
      installmentIndex: row['installment_index'] as int?,
      transactionId: row['transaction_id'] as String?,
      note: row['note'] as String?,
    );
  }

  Future<void> _mirrorBill(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final serverId = row['id'] as String;
    final localId = await _support.localIdForServer(
      table: 'subscriptions',
      serverId: serverId,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final accountId =
        await _support.localAccountId(row['server_account_id'] as String?);
    final merchantId = await _support.localMerchantId(row['name'] as String);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO subscriptions(
        id, merchant_id, amount, period, next_due_date, is_confirmed,
        reminder_on, name, type, currency, frequency, custom_interval_days,
        note, created_at, status, account_id, total_installments, paid_count,
        manual_paid_amount, total_purchase_amount, lender_name, interest_rate,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        merchant_id = excluded.merchant_id, amount = excluded.amount,
        period = excluded.period, next_due_date = excluded.next_due_date,
        is_confirmed = excluded.is_confirmed, reminder_on = excluded.reminder_on,
        name = excluded.name, type = excluded.type, currency = excluded.currency,
        frequency = excluded.frequency,
        custom_interval_days = excluded.custom_interval_days, note = excluded.note,
        status = excluded.status, account_id = excluded.account_id,
        total_installments = excluded.total_installments,
        paid_count = excluded.paid_count,
        manual_paid_amount = excluded.manual_paid_amount,
        total_purchase_amount = excluded.total_purchase_amount,
        lender_name = excluded.lender_name, interest_rate = excluded.interest_rate,
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      merchantId,
      (row['amount'] as num).toDouble(),
      row['frequency'] as String,
      row['next_due_date'] as String,
      boolToSql(row['is_confirmed'] as bool? ?? false),
      boolToSql(row['reminder_on'] as bool? ?? true),
      row['name'] as String,
      row['type'] as String,
      row['currency'] as String,
      row['frequency'] as String,
      row['custom_interval_days'] as int?,
      row['note'] as String?,
      row['created_at'] as String,
      row['status'] as String,
      accountId,
      row['total_installments'] as int?,
      row['paid_count'] as int?,
      (row['manual_paid_amount'] as num?)?.toDouble(),
      (row['total_purchase_amount'] as num?)?.toDouble(),
      row['lender_name'] as String?,
      (row['interest_rate'] as num?)?.toDouble(),
      serverId,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }

  Future<void> _mirrorPayment(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final billLocalId = await _support.localIdForServer(
      table: 'subscriptions',
      serverId: row['subscription_id'] as String,
    );
    final localId = await _support.localIdForServer(
      table: 'bill_payments',
      serverId: row['id'] as String,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final transactionServerId = row['transaction_id'] as String?;
    String? transactionLocalId;
    if (transactionServerId != null) {
      final local = await _support.db.customSelect(
        'SELECT id FROM transactions WHERE server_id = ? LIMIT 1;',
        variables: [
          Variable.withString(transactionServerId),
        ],
      ).getSingleOrNull();
      transactionLocalId = local?.readNullable<String>('id');
    }
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO bill_payments(
        id, bill_id, amount, currency, period_start, period_end, paid_at,
        installment_index, transaction_id, note, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        bill_id = excluded.bill_id, amount = excluded.amount,
        currency = excluded.currency, period_start = excluded.period_start,
        period_end = excluded.period_end, paid_at = excluded.paid_at,
        installment_index = excluded.installment_index,
        transaction_id = excluded.transaction_id, note = excluded.note,
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      billLocalId,
      (row['amount'] as num).toDouble(),
      row['currency'] as String,
      row['period_start'] as String,
      row['period_end'] as String,
      row['paid_at'] as String,
      row['installment_index'] as int?,
      transactionLocalId,
      row['note'] as String?,
      row['id'] as String,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }
}
