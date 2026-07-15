import 'package:drift/drift.dart' show Variable;
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/services/duplicate_transaction_detector.dart';
import '../../engine/parser/card_network.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// حجم الصفحة عند جلب صفوف للتجميع في Dart — أقل من الحد الافتراضي لـ
/// PostgREST (max_rows=1000) حتى لا نعتمد على القيمة الافتراضية ضمنيًا.
const _pageSize = 500;

/// مستودع العمليات المباشر على Supabase — كل القراءات والكتابات هنا مباشرة
/// على user_transactions عندما تكون علامة transactions_supabase_primary
/// مفعّلة؛ لا سقوط (fallback) صامت إلى Drift لأي دالة، بما فيها التقارير
/// المُجمَّعة (merchantBreakdown/recurringCandidates/getCardSummaries).
class SupabaseTransactionRepository implements TransactionRepository {
  SupabaseTransactionRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : _db = db,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _requireUserId() async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    return uid;
  }

  // ── ترحيل النوع/الاتجاه بين Supabase (direction/transaction_type) و
  //    التمثيل المحلي (TransactionTypeEntity/TransactionDirectionEntity) ──

  static TransactionDirectionEntity directionFromServer(String? value) {
    switch (value) {
      case 'debit':
        return TransactionDirectionEntity.debit;
      case 'credit':
        return TransactionDirectionEntity.credit;
      default:
        return TransactionDirectionEntity.unknown;
    }
  }

  static String directionToServer(TransactionDirectionEntity? direction) {
    switch (direction) {
      case TransactionDirectionEntity.debit:
        return 'debit';
      case TransactionDirectionEntity.credit:
        return 'credit';
      default:
        return 'unknown';
    }
  }

  // ملاحظة: transaction_type على الخادم لا يميّز withdrawal عن payment (كلاهما
  // 'expense') — رحلة كتابة/قراءة لعملية withdrawal تعود كـ payment. توثيق
  // هذا القيد في التقرير النهائي، وليس إخفاءه.
  static TransactionTypeEntity typeFromServer(String? transactionType) {
    switch (transactionType) {
      case 'transfer':
        return TransactionTypeEntity.transfer;
      case 'refund':
        return TransactionTypeEntity.refund;
      case 'income':
        return TransactionTypeEntity.income;
      case 'expense':
        return TransactionTypeEntity.payment;
      default:
        return TransactionTypeEntity.unknown;
    }
  }

  static TransactionStatus statusFromServer(String? value) {
    return switch (value) {
      'pending' => TransactionStatus.pending,
      'ignored' => TransactionStatus.ignored,
      _ => TransactionStatus.confirmed,
    };
  }

  static String typeToServer(
    TransactionTypeEntity type,
    TransactionDirectionEntity? direction,
  ) {
    switch (type) {
      case TransactionTypeEntity.transfer:
        return 'transfer';
      case TransactionTypeEntity.refund:
        return 'refund';
      case TransactionTypeEntity.income:
        return 'income';
      case TransactionTypeEntity.payment:
      case TransactionTypeEntity.withdrawal:
        return 'expense';
      case TransactionTypeEntity.unknown:
        return direction == TransactionDirectionEntity.credit
            ? 'income'
            : direction == TransactionDirectionEntity.debit
                ? 'expense'
                : 'unknown';
    }
  }

  // category_id على الخادم هو مفتاح الفئة (categories.key)، لكن كل نقاط
  // العرض في الواجهة (transactions_screen/transaction_details_screen/
  // dashboard إلخ) تستدعي catalog.byId(tx.categoryId) حصرًا — لا أحد
  // يجرّب byKey. لذا يجب ترجمة المفتاح إلى معرّف Drift المحلي هنا قبل بناء
  // الكيان، وإلا تظهر كل عملية Supabase-primary كـ«غير مصنّف» في الواجهة.
  Future<TransactionEntity> _fromServerRow(Map<String, dynamic> row) async {
    final direction = directionFromServer(row['direction'] as String?);
    final localCategoryId =
        await _localCategoryIdForKey(row['category_id'] as String?);
    final metadata = _metadata(row);
    final source = _transactionSourceFromMetadata(
      metadata['transaction_source'] as String?,
      row['source'] as String?,
      metadata['parser_source'] as String?,
    );
    final comparisonTimestamp = _parseDate(row['comparison_timestamp']) ??
        _parseDate(metadata['comparison_timestamp']);
    final comparisonSource = _comparisonSourceFromServer(
      row['comparison_timestamp_source'] as String? ??
          metadata['comparison_timestamp_source'] as String?,
    );
    return TransactionEntity(
      id: row['id'] as String,
      amount: (row['amount'] as num).toDouble(),
      currency: row['currency'] as String,
      accountId: row['server_account_id'] as String?,
      rawMerchant: row['merchant'] as String?,
      categoryId: localCategoryId,
      type: typeFromServer(row['transaction_type'] as String?),
      source: source,
      cardLast4: metadata['last4'] as String?,
      balanceAfter: (row['balance_after'] as num?)?.toDouble(),
      note: row['description'] as String?,
      occurredAt: DateTime.parse(row['occurred_at'] as String).toUtc(),
      rawMessage: '',
      parseConfidence: (row['confidence'] as num?)?.toDouble() ?? 0,
      status: statusFromServer(row['status'] as String?),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
      direction: direction,
      foreignAmount: (row['foreign_amount'] as num?)?.toDouble(),
      foreignCurrency: row['foreign_currency'] as String?,
      transactionTimeFromSms: _parseDate(metadata['transaction_time_from_sms']),
      smsReceivedAt: _parseDate(metadata['sms_received_at']),
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: comparisonSource,
      duplicateStatus: metadata['duplicate_status'] == 'suspicious_duplicate'
          ? DuplicateStatus.suspiciousDuplicate
          : DuplicateStatus.normal,
      possibleDuplicateOfTransactionId:
          metadata['possible_duplicate_of_transaction_id'] as String?,
      duplicateReason: metadata['duplicate_reason'] as String?,
      serverId: row['id'] as String,
      syncedAt: DateTime.now().toUtc(),
      serverUpdatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
      syncStatus: SyncStatus.synced,
    );
  }

  /// Shared mapper for authenticated RPCs (for example plan_transactions)
  /// that return canonical user_transactions rows.
  Future<TransactionEntity> entityFromServerRow(Map<String, dynamic> row) =>
      _fromServerRow(row);

  static Map<String, dynamic> _metadata(Map<String, dynamic> row) {
    final value = row['metadata'];
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static ComparisonTimestampSource _comparisonSourceFromServer(String? value) {
    return value == 'sms_body'
        ? ComparisonTimestampSource.smsBody
        : ComparisonTimestampSource.receivedAt;
  }

  static TransactionSourceEntity _transactionSourceFromMetadata(
    String? localSource,
    String? serverSource,
    String? parserSource,
  ) {
    if (parserSource == 'ai_hybrid') {
      return TransactionSourceEntity.aiParsed;
    }
    if (localSource != null) {
      for (final value in TransactionSourceEntity.values) {
        if (value.name == localSource) return value;
      }
    }
    return sourceFromServer(serverSource);
  }

  static TransactionSourceEntity sourceFromServer(String? source) {
    switch (source) {
      case 'ios_shortcut':
        return TransactionSourceEntity.bank;
      case 'android_sms':
        return TransactionSourceEntity.bank;
      case 'manual':
        return TransactionSourceEntity.unknown;
      case 'import':
        return TransactionSourceEntity.unknown;
      case 'share_extension':
        return TransactionSourceEntity.aiParsed;
      default:
        return TransactionSourceEntity.unknown;
    }
  }

  static String sourceToServer(TransactionSourceEntity source) {
    switch (source) {
      case TransactionSourceEntity.bank:
        // Old Drift rows do not distinguish iOS from Android. Marking them as
        // import is honest provenance; new backend captures keep ios_shortcut.
        return 'import';
      case TransactionSourceEntity.card:
        return 'import';
      case TransactionSourceEntity.wallet:
        return 'manual';
      case TransactionSourceEntity.aiParsed:
        return 'share_extension';
      case TransactionSourceEntity.unknown:
        return 'manual';
    }
  }

  // ── أدوات ترقيم الصفحات — أنظر القسم 3/6 من الخطة المعتمدة ──

  Future<List<Map<String, dynamic>>> _fetchAllRows(
    PostgrestFilterBuilder<dynamic> Function() buildQuery,
  ) async {
    final rows = <Map<String, dynamic>>[];
    var from = 0;
    final upperBoundary = DateTime.now().toUtc().toIso8601String();
    while (true) {
      final page = await buildQuery()
          .lte('created_at', upperBoundary)
          .order('occurred_at')
          .order('id')
          .range(from, from + _pageSize - 1);
      final batch = List<Map<String, dynamic>>.from(page as List);
      rows.addAll(batch);
      if (batch.length < _pageSize) break;
      from += _pageSize;
    }
    return rows;
  }

  /// نطاق نصف مفتوح: occurred_at >= from و occurred_at < to (وليس <=)، لمنع
  /// العدّ المزدوج عند حدود الشهر ومشاكل الدقة عند 23:59:59. التحويل لـ UTC
  /// دفاعي هنا حتى لو مرَّر المستدعي DateTime محليًا.
  PostgrestFilterBuilder<dynamic> _dateRangeQuery(
    PostgrestFilterBuilder<dynamic> query,
    DateTime fromInclusive,
    DateTime toExclusive,
  ) {
    return query
        .gte('occurred_at', fromInclusive.toUtc().toIso8601String())
        .lt('occurred_at', toExclusive.toUtc().toIso8601String());
  }

  // ── قراءة: عمليات بسيطة ──

  @override
  Future<TransactionEntity?> getById(String id) async {
    final uid = await _requireUserId();
    try {
      final row = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .eq('id', id)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : await _fromServerRow(row);
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  /// Looks up a backend capture by its stable relay payload key. This is used
  /// when Flutter opens after an APNs notification: an existing canonical row
  /// is mirrored and returned instead of importing the relay as a second row.
  Future<TransactionEntity?> getBySourcePayloadId(String payloadId) async {
    final uid = await _requireUserId();
    try {
      final row = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .eq('source_payload_id', payloadId)
          .isFilter('deleted_at', null)
          .maybeSingle();
      if (row == null) return null;
      await _mirrorUpsertRow(localId: null, row: row);
      return _fromServerRow(row);
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<TransactionEntity>> getAll() async {
    final uid = await _requireUserId();
    try {
      final rows = await _fetchAllRows(
        () => _getClient()
            .from('user_transactions')
            .select()
            .eq('user_id', uid)
            .isFilter('deleted_at', null),
      );
      final entities = await Future.wait(rows.map(_fromServerRow));
      return entities.reversed.toList();
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<TransactionEntity>> getPage({
    required int offset,
    int limit = _pageSize,
  }) async {
    final uid = await _requireUserId();
    try {
      final rows = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('occurred_at', ascending: false)
          .order('id', ascending: false)
          .range(offset, offset + limit - 1);
      return await Future.wait(
        (rows as List).map((r) => _fromServerRow(r as Map<String, dynamic>)),
      );
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<TransactionEntity>> getRecent({
    int limit = 5,
    String? accountId,
  }) async {
    final uid = await _requireUserId();
    try {
      var query = _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null);
      if (accountId != null) query = query.eq('server_account_id', accountId);
      final rows = await query
          .order('occurred_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit);
      return await Future.wait(
        (rows as List).map((r) => _fromServerRow(r as Map<String, dynamic>)),
      );
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<TransactionEntity>> getByCard(String last4) async {
    final uid = await _requireUserId();
    try {
      // يُفضَّل ترشيح last4 عبر مسار jsonb مباشرة على الخادم؛ إن ثبت أن
      // بنية postgrest-dart الحالية لا تدعمه بشكل موثوق (يُتحقَّق منه
      // باختبار تكامل حقيقي)، نجلب الأعمدة الدنيا ونرشّح last4 في Dart —
      // لا نُعيد نتائج بطاقة خاطئة بصمت مهما كان المسار.
      List<Map<String, dynamic>> rows;
      try {
        rows = await _fetchAllRows(
          () => _getClient()
              .from('user_transactions')
              .select()
              .eq('user_id', uid)
              .isFilter('deleted_at', null)
              .eq('metadata->>last4', last4),
        );
      } catch (_) {
        final all = await _fetchAllRows(
          () => _getClient()
              .from('user_transactions')
              .select()
              .eq('user_id', uid)
              .isFilter('deleted_at', null),
        );
        rows = all
            .where((r) =>
                (r['metadata'] as Map<String, dynamic>?)?['last4'] == last4)
            .toList();
      }
      final entities = await Future.wait(rows.map(_fromServerRow));
      return entities.reversed.toList();
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async {
    final uid = await _requireUserId();
    try {
      final normalized = rawMerchant.trim();
      final row = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .eq('amount', amount)
          .eq('occurred_at', occurredAt.toUtc().toIso8601String())
          .ilike('merchant', normalized)
          .order('occurred_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return row == null ? null : await _fromServerRow(row);
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required double amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) async {
    final uid = await _requireUserId();
    try {
      // user_transactions لا تخزّن foreign_amount/foreign_currency اليوم —
      // مطابقة العملة الأجنبية غير متاحة عبر المسار المباشر على Supabase؛
      // نطابق فقط amount+currency الأساسيين.
      final rows = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .eq('amount', amount)
          .ilike('currency', currency.trim())
          .order('occurred_at', ascending: false);
      final candidates = await Future.wait(
        (rows as List).map((r) => _fromServerRow(r as Map<String, dynamic>)),
      );
      final result = const DuplicateTransactionDetector().detect(
        input: DuplicateTransactionInput(
          amount: amount,
          currency: currency,
          merchantOrDescription: merchantOrDescription,
          cardLast4: cardLast4,
          comparisonTimestamp: comparisonTimestamp,
          comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
        ),
        existingTransactions: candidates,
      );
      return result.existing;
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  // ── قراءة: تجميعات محدودة بفترة (تصفية على الخادم + تجميع في Dart) ──

  @override
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    final rows = await _totalsRows(from, to, accountId);
    return rows
        .where((r) => r['transaction_type'] == 'expense')
        .fold<double>(0, (sum, r) => sum + (r['amount'] as num).toDouble());
  }

  @override
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    final rows = await _totalsRows(from, to, accountId);
    return rows
        .where((r) => r['transaction_type'] == 'income')
        .fold<double>(0, (sum, r) => sum + (r['amount'] as num).toDouble());
  }

  @override
  Future<double?> latestBalanceAfter({String? accountId}) async {
    final uid = await _requireUserId();
    try {
      var query = _getClient()
          .from('user_transactions')
          .select('balance_after, occurred_at')
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .not('balance_after', 'is', null);
      if (accountId != null) query = query.eq('server_account_id', accountId);
      final row = await query
          .order('occurred_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return (row?['balance_after'] as num?)?.toDouble();
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _totalsRows(from, to, null,
        columns: 'amount,currency,transaction_type');
    final byCurrency = <String, (double, double)>{};
    for (final r in rows) {
      final currency = r['currency'] as String;
      final amount = (r['amount'] as num).toDouble();
      final (expense, income) = byCurrency[currency] ?? (0.0, 0.0);
      if (r['transaction_type'] == 'expense') {
        byCurrency[currency] = (expense + amount, income);
      } else if (r['transaction_type'] == 'income') {
        byCurrency[currency] = (expense, income + amount);
      }
    }
    final result = byCurrency.entries
        .map((e) => CurrencyTotal(
            currency: e.key, expense: e.value.$1, income: e.value.$2))
        .toList()
      ..sort((a, b) => b.expense.compareTo(a.expense));
    return result;
  }

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    final rows = await _totalsRows(from, to, accountId,
        columns: 'amount,occurred_at,transaction_type');
    final byDay = <DateTime, double>{};
    for (final r in rows) {
      if (r['transaction_type'] != 'expense') continue;
      final occurredAt = DateTime.parse(r['occurred_at'] as String).toLocal();
      final day = DateTime(occurredAt.year, occurredAt.month, occurredAt.day);
      byDay[day] = (byDay[day] ?? 0) + (r['amount'] as num).toDouble();
    }
    final result = byDay.entries
        .map((e) => DailySpend(day: e.key, total: e.value))
        .toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return result;
  }

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    final rows = await _totalsRows(
      from,
      to,
      accountId,
      columns: 'amount,category_id,transaction_type',
    );
    final byCategory = <String, (double, int)>{};
    for (final r in rows) {
      if (r['transaction_type'] != 'expense') continue;
      final categoryKey = r['category_id'] as String?;
      if (categoryKey == null) continue;
      final categoryId = await _localCategoryIdForKey(categoryKey);
      if (categoryId == null) continue;
      final (total, count) = byCategory[categoryId] ?? (0.0, 0);
      byCategory[categoryId] =
          (total + (r['amount'] as num).toDouble(), count + 1);
    }
    final result = byCategory.entries
        .map((e) => CategorySpend(
            categoryId: e.key, total: e.value.$1, count: e.value.$2))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return result;
  }

  @override
  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    final categoryKey = await _categoryKeyForLocalId(categoryId) ?? categoryId;
    final rows = await _totalsRows(
      from,
      to,
      accountId,
      columns: 'amount,category_id,transaction_type',
    );
    return rows
        .where((r) =>
            r['transaction_type'] == 'expense' &&
            r['category_id'] == categoryKey)
        .fold<double>(0, (sum, r) => sum + (r['amount'] as num).toDouble());
  }

  Future<List<Map<String, dynamic>>> _totalsRows(
    DateTime from,
    DateTime to,
    String? accountId, {
    String columns = 'amount,transaction_type',
  }) async {
    final uid = await _requireUserId();
    try {
      return await _fetchAllRows(() {
        var query = _getClient()
            .from('user_transactions')
            .select(columns)
            .eq('user_id', uid)
            .isFilter('deleted_at', null);
        if (accountId != null) query = query.eq('server_account_id', accountId);
        return _dateRangeQuery(query, from, to);
      });
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  // ── قراءة: تجميعات على كامل التاريخ (بدون RPC في المرحلة 2 — أنظر القيد
  //    الموثَّق في التقرير النهائي بخصوص الأداء لهذه الحالة تحديدًا) ──

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
    String? accountId,
  }) async {
    final rows = await _totalsRows(
      from,
      to,
      accountId,
      columns: 'amount,merchant,transaction_type',
    );
    final byMerchant = <String, (double, int)>{};
    for (final r in rows) {
      if (r['transaction_type'] != 'expense') continue;
      final merchant = (r['merchant'] as String?)?.trim();
      if (merchant == null || merchant.isEmpty) continue;
      final key = merchant.toLowerCase();
      final (total, count) = byMerchant[key] ?? (0.0, 0);
      byMerchant[key] = (total + (r['amount'] as num).toDouble(), count + 1);
    }
    final result = byMerchant.entries
        .map((e) =>
            MerchantSpend(name: e.key, total: e.value.$1, count: e.value.$2))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return result.take(limit).toList();
  }

  @override
  Future<List<RecurringCandidate>> recurringCandidates(
      {String? accountId}) async {
    final uid = await _requireUserId();
    try {
      // لا حدّ زمني في الواجهة الأصلية لهذه الدالة — جلب كامل تاريخ
      // المستخدم مرقّمًا بالصفحات؛ قيد أداء موثَّق للمرحلة 2، يُستبدل
      // بـ RPC في المرحلة 3.
      final rows = await _fetchAllRows(() {
        var query = _getClient()
            .from('user_transactions')
            .select('amount,merchant,occurred_at,transaction_type')
            .eq('user_id', uid)
            .isFilter('deleted_at', null)
            .eq('transaction_type', 'expense');
        if (accountId != null) query = query.eq('server_account_id', accountId);
        return query;
      });
      final byMerchant = <String, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        final merchant = (r['merchant'] as String?)?.trim();
        if (merchant == null || merchant.isEmpty) continue;
        byMerchant.putIfAbsent(merchant.toLowerCase(), () => []).add(r);
      }
      final result = <RecurringCandidate>[];
      byMerchant.forEach((key, group) {
        final months = group.map((r) {
          final d = DateTime.parse(r['occurred_at'] as String).toUtc();
          return '${d.year}-${d.month}';
        }).toSet();
        if (months.length < 2) return;
        final avg = group.fold<double>(
                0, (s, r) => s + (r['amount'] as num).toDouble()) /
            group.length;
        result.add(RecurringCandidate(
          merchantId: key,
          name: group.first['merchant'] as String,
          averageAmount: avg,
          monthsSeen: months.length,
        ));
      });
      return result;
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<List<CardSummary>> getCardSummaries() async {
    final uid = await _requireUserId();
    try {
      final rows = await _fetchAllRows(
        () => _getClient()
            .from('user_transactions')
            .select('amount,metadata,transaction_type')
            .eq('user_id', uid)
            .isFilter('deleted_at', null),
      );
      final byCard = <String, (double, double, int)>{};
      for (final r in rows) {
        final last4 =
            (r['metadata'] as Map<String, dynamic>?)?['last4'] as String?;
        if (last4 == null) continue;
        final amount = (r['amount'] as num).toDouble();
        final (out, inn, count) = byCard[last4] ?? (0.0, 0.0, 0);
        final isOut = r['transaction_type'] == 'expense';
        final isIn = r['transaction_type'] == 'income' ||
            r['transaction_type'] == 'refund';
        byCard[last4] =
            (out + (isOut ? amount : 0), inn + (isIn ? amount : 0), count + 1);
      }
      final result = byCard.entries
          .map((e) => CardSummary(
                last4: e.key,
                // شبكة البطاقة كانت تُستنتج من raw_message نصيًا محليًا؛
                // هذا العمود غير مخزَّن على الخادم، فتبقى unknown هنا.
                network: CardNetwork.unknown,
                totalOut: e.value.$1,
                totalIn: e.value.$2,
                count: e.value.$3,
              ))
          .toList()
        ..sort((a, b) =>
            (b.totalOut + b.totalIn).compareTo(a.totalOut + a.totalIn));
      return result;
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  /// عملية إصلاح كاش لمرّة واحدة — أنظر التوثيق المطابق في
  /// SupabaseAccountRepository.repairLocalCache. localId يُترَك null دائمًا
  /// هنا لأن client_request_id قد يحمل بادئة backfill_transaction_ لصفوف
  /// الترحيل، فلا يصلح مطابقةً مباشرة لمعرّف Drift المحلي — الاعتماد على
  /// server_id الموجود مسبقًا (أو توليد معرّف كاش جديد إن لم يكن هناك) أدق.
  Future<void> repairLocalCache() async {
    final uid = await _requireUserId();
    List<Map<String, dynamic>> rows;
    try {
      rows = await _fetchAllRows(
        () =>
            _getClient().from('user_transactions').select().eq('user_id', uid),
      );
    } catch (e) {
      throw mapSupabaseError(e);
    }
    final serverIds = rows.map((row) => row['id'] as String).toSet();
    final cached = await _db
        .customSelect(
          'SELECT id, server_id FROM transactions WHERE server_id IS NOT NULL;',
        )
        .get();
    for (final local in cached) {
      final serverId = local.read<String>('server_id');
      if (serverIds.contains(serverId)) continue;
      await _db.customStatement(
        "UPDATE transactions SET status = 'ignored', sync_status = 'synced' WHERE id = ?;",
        [local.read<String>('id')],
      );
    }
    for (final row in rows) {
      final isDeleted = row['deleted_at'] != null;
      await _mirrorUpsertRow(localId: null, row: row, isDeleted: isDeleted);
    }
    await clearFinancialCacheDirty(_db, transactionsCacheEntityType);
  }

  // ── كتابة ──

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) async {
    final uid = await _requireUserId();
    // clientRequestId يُولَّد مرّة واحدة قبل أول طلب (نفس transaction.id إن
    // وُجد) — لا يُعاد توليده عند إعادة المحاولة، أنظر عقد التكرار في الخطة.
    final clientRequestId =
        transaction.id.isEmpty ? IdGenerator.next() : transaction.id;
    final direction =
        transaction.direction ?? TransactionDirectionEntity.unknown;
    final metadata = <String, dynamic>{
      'transaction_source': transaction.source.name,
      if (transaction.cardLast4 != null) 'last4': transaction.cardLast4,
      if (transaction.transactionTimeFromSms != null)
        'transaction_time_from_sms':
            transaction.transactionTimeFromSms!.toUtc().toIso8601String(),
      if (transaction.smsReceivedAt != null)
        'sms_received_at': transaction.smsReceivedAt!.toUtc().toIso8601String(),
      'comparison_timestamp_source': transaction.comparisonTimestampSource ==
              ComparisonTimestampSource.smsBody
          ? 'sms_body'
          : 'received_at',
      'duplicate_status':
          transaction.duplicateStatus == DuplicateStatus.suspiciousDuplicate
              ? 'suspicious_duplicate'
              : 'normal',
      if (transaction.possibleDuplicateOfTransactionId != null)
        'possible_duplicate_of_transaction_id':
            transaction.possibleDuplicateOfTransactionId,
      if (transaction.duplicateReason != null)
        'duplicate_reason': transaction.duplicateReason,
    };

    Map<String, dynamic> row;
    try {
      row = await _getClient()
          .from('user_transactions')
          .insert({
            'user_id': uid,
            'client_request_id': clientRequestId,
            'amount': transaction.amount,
            'currency': transaction.currency,
            'merchant': transaction.rawMerchant,
            'description': transaction.note,
            'category_id': categoryKey ?? transaction.categoryId,
            'occurred_at': transaction.occurredAt.toUtc().toIso8601String(),
            'source': sourceToServer(transaction.source),
            'confidence': transaction.parseConfidence,
            'direction': directionToServer(direction),
            'transaction_type': typeToServer(transaction.type, direction),
            'server_account_id': transaction.accountId,
            'balance_after': transaction.balanceAfter,
            'status': transaction.status.name,
            'foreign_amount': transaction.foreignAmount,
            'foreign_currency': transaction.foreignCurrency,
            'comparison_timestamp':
                transaction.comparisonTimestamp?.toUtc().toIso8601String(),
            'comparison_timestamp_source':
                transaction.comparisonTimestampSource ==
                        ComparisonTimestampSource.smsBody
                    ? 'sms_body'
                    : 'received_at',
            'metadata': metadata,
          })
          .select()
          .single();
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        final existing = await _getClient()
            .from('user_transactions')
            .select()
            .eq('user_id', uid)
            .eq('client_request_id', clientRequestId)
            .maybeSingle();
        if (existing == null) throw mapSupabaseError(e);
        row = existing;
      } else {
        throw mapSupabaseError(e);
      }
    } catch (e) {
      throw mapSupabaseError(e);
    }

    await _mirrorUpsertRow(localId: clientRequestId, row: row);
    return await _fromServerRow(row);
  }

  /// Relay recovery for direct iOS capture. The stable source payload key is
  /// sent on the insert, so a backend timeout followed by app-open recovery is
  /// still idempotent against the backend write.
  Future<TransactionEntity> saveCapturedTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    required String payloadId,
  }) async {
    final uid = await _requireUserId();
    final direction =
        transaction.direction ?? TransactionDirectionEntity.unknown;
    final clientRequestId = 'capture_$payloadId';
    final metadata = <String, dynamic>{
      'transaction_source': transaction.source.name,
      if (transaction.cardLast4 != null) 'last4': transaction.cardLast4,
      if (transaction.transactionTimeFromSms != null)
        'transaction_time_from_sms':
            transaction.transactionTimeFromSms!.toUtc().toIso8601String(),
      if (transaction.smsReceivedAt != null)
        'sms_received_at': transaction.smsReceivedAt!.toUtc().toIso8601String(),
      'comparison_timestamp_source': transaction.comparisonTimestampSource ==
              ComparisonTimestampSource.smsBody
          ? 'sms_body'
          : 'received_at',
      'duplicate_status':
          transaction.duplicateStatus == DuplicateStatus.suspiciousDuplicate
              ? 'suspicious_duplicate'
              : 'normal',
    };
    final values = <String, dynamic>{
      'user_id': uid,
      'client_request_id': clientRequestId,
      'source_payload_id': payloadId,
      'amount': transaction.amount,
      'currency': transaction.currency,
      'merchant': transaction.rawMerchant,
      'description': transaction.note,
      'category_id': categoryKey ?? transaction.categoryId,
      'occurred_at': transaction.occurredAt.toUtc().toIso8601String(),
      'source': 'ios_shortcut',
      'confidence': transaction.parseConfidence,
      'direction': directionToServer(direction),
      'transaction_type': typeToServer(transaction.type, direction),
      'server_account_id': transaction.accountId,
      'balance_after': transaction.balanceAfter,
      'status': transaction.status.name,
      'comparison_timestamp':
          transaction.comparisonTimestamp?.toUtc().toIso8601String(),
      'comparison_timestamp_source': transaction.comparisonTimestampSource ==
              ComparisonTimestampSource.smsBody
          ? 'sms_body'
          : 'received_at',
      'metadata': metadata,
    };

    Map<String, dynamic> row;
    try {
      row = await _getClient()
          .from('user_transactions')
          .insert(values)
          .select()
          .single();
    } on PostgrestException catch (error) {
      if (error.code != '23505') throw mapSupabaseError(error);
      final existing = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .eq('source_payload_id', payloadId)
          .maybeSingle();
      if (existing == null) throw mapSupabaseError(error);
      row = existing;
    } catch (error) {
      throw mapSupabaseError(error);
    }
    await _mirrorUpsertRow(localId: null, row: row);
    return _fromServerRow(row);
  }

  @override
  Future<TransactionEntity> confirm(String id) async {
    // الحالة 'confirmed' محليًا فقط — لا عمود status مطابق على user_transactions
    // (كل صف هناك مؤكَّد ضمنيًا بوجوده). لا تغيير فعلي مطلوب على الخادم غير
    // تصحيح transaction_type='unknown' إن وُجد، بنفس منطق التأريض المحلي.
    final uid = await _requireUserId();
    Map<String, dynamic>? row;
    try {
      final current = await _getClient()
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .eq('id', id)
          .maybeSingle();
      if (current == null) throw const NotFoundRepoException();
      if (current['transaction_type'] == 'unknown') {
        final grounded =
            current['direction'] == 'credit' ? 'income' : 'expense';
        row = await _getClient()
            .from('user_transactions')
            .update({
              'transaction_type': grounded,
              'status': 'confirmed',
            })
            .eq('user_id', uid)
            .eq('id', id)
            .select()
            .maybeSingle();
      } else if (current['status'] != 'confirmed') {
        row = await _getClient()
            .from('user_transactions')
            .update({'status': 'confirmed'})
            .eq('user_id', uid)
            .eq('id', id)
            .select()
            .maybeSingle();
      } else {
        row = current;
      }
    } catch (e) {
      if (e is RepoException) rethrow;
      throw mapSupabaseError(e);
    }
    if (row == null) throw const NotFoundRepoException();
    await _mirrorUpsertRow(localId: null, row: row);
    return await _fromServerRow(row);
  }

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) =>
      _updateFields(transactionId, {'category_id': categoryKey});

  @override
  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  }) async {
    final categoryKey =
        categoryId == null ? null : await _categoryKeyForLocalId(categoryId);
    final direction = switch (type) {
      TransactionTypeEntity.income || TransactionTypeEntity.refund => 'credit',
      TransactionTypeEntity.payment ||
      TransactionTypeEntity.withdrawal =>
        'debit',
      _ => 'unknown',
    };
    return _updateFields(transactionId, {
      'amount': amount,
      'currency': currency,
      'transaction_type': typeToServer(type, null),
      'direction': direction,
      'occurred_at': occurredAt.toUtc().toIso8601String(),
      'comparison_timestamp': occurredAt.toUtc().toIso8601String(),
      'merchant': rawMerchant,
      'category_id': categoryKey,
      'description': note,
      if (accountId != null) 'server_account_id': accountId,
    });
  }

  @override
  Future<void> deleteTransaction(String id) async {
    final uid = await _requireUserId();
    Map<String, dynamic>? row;
    try {
      row = await _getClient()
          .from('user_transactions')
          .update({
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
            'status': 'ignored',
          })
          .eq('user_id', uid)
          .eq('id', id)
          .select()
          .maybeSingle();
    } catch (e) {
      throw mapSupabaseError(e);
    }
    if (row == null) throw const NotFoundRepoException();
    await _mirrorDeleteByServerId(id);
  }

  @override
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
  }) async {
    await _updateFields(transactionId, {'server_account_id': accountId});
  }

  @override
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  }) async {
    await _updateFields(
      transactionId,
      {
        'metadata': cardLast4 == null ? {} : {'last4': cardLast4}
      },
    );
  }

  @override
  Future<void> updateAmount({
    required String transactionId,
    required double amount,
  }) async {
    await _updateFields(transactionId, {'amount': amount});
  }

  Future<TransactionEntity> _updateFields(
    String id,
    Map<String, dynamic> fields,
  ) async {
    final uid = await _requireUserId();
    Map<String, dynamic>? row;
    try {
      row = await _getClient()
          .from('user_transactions')
          .update(fields)
          .eq('user_id', uid)
          .eq('id', id)
          .select()
          .maybeSingle();
    } catch (e) {
      throw mapSupabaseError(e);
    }
    if (row == null) throw const NotFoundRepoException();
    await _mirrorUpsertRow(localId: null, row: row);
    return await _fromServerRow(row);
  }

  // ── مرآة الكاش المحلي (Drift) — بعد النجاح فقط ──

  Future<String?> _localIdForServerId(String serverId) async {
    final row = await _db.customSelect(
      'SELECT id FROM transactions WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  /// transactions محليًا ليس لها deleted_at — الحذف الناعم يتم عبر
  /// status='ignored' (يطابق DriftTransactionRepository.deleteTransaction).
  /// كذلك category_id محليًا FK على categories(id) وليس categories(key) كما
  /// على الخادم، فيلزم ترجمة المفتاح إلى المعرّف المحلي قبل الكتابة.
  Future<String?> _localCategoryIdForKey(String? key) async {
    if (key == null) return null;
    final row = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  Future<String?> _categoryKeyForLocalId(String? localId) async {
    if (localId == null) return null;
    final row = await _db.customSelect(
      'SELECT key FROM categories WHERE id = ? OR key = ? LIMIT 1;',
      variables: [
        Variable.withString(localId),
        Variable.withString(localId),
      ],
    ).getSingleOrNull();
    return row?.readNullable<String>('key');
  }

  Future<void> _mirrorUpsertRow({
    required String? localId,
    required Map<String, dynamic> row,
    bool isDeleted = false,
  }) async {
    try {
      final serverId = row['id'] as String;
      final resolvedLocalId =
          localId ?? await _localIdForServerId(serverId) ?? IdGenerator.next();
      final entity = await _fromServerRow(row);
      final localCategoryId = entity.categoryId;
      final now = dateTimeToSql(DateTime.now().toUtc());
      final status = isDeleted ? 'ignored' : entity.status.name;
      await _db.customStatement(
        '''
          INSERT INTO transactions(
            id, amount, currency, account_id, raw_merchant, category_id, type, source,
            card_last4, balance_after, note, occurred_at, raw_message, parse_confidence,
            status, created_at, updated_at, direction,
            server_id, synced_at, server_updated_at, sync_status
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
          ON CONFLICT(id) DO UPDATE SET
            amount = excluded.amount,
            currency = excluded.currency,
            account_id = excluded.account_id,
            raw_merchant = excluded.raw_merchant,
            category_id = excluded.category_id,
            type = excluded.type,
            source = excluded.source,
            card_last4 = excluded.card_last4,
            balance_after = excluded.balance_after,
            note = excluded.note,
            occurred_at = excluded.occurred_at,
            status = excluded.status,
            updated_at = excluded.updated_at,
            direction = excluded.direction,
            server_id = excluded.server_id,
            synced_at = excluded.synced_at,
            server_updated_at = excluded.server_updated_at,
            sync_status = 'synced';
        ''',
        [
          resolvedLocalId,
          entity.amount,
          entity.currency,
          entity.accountId,
          entity.rawMerchant,
          localCategoryId,
          entity.type.name,
          entity.source.name,
          entity.cardLast4,
          entity.balanceAfter,
          entity.note,
          dateTimeToSql(entity.occurredAt),
          entity.rawMessage,
          entity.parseConfidence,
          status,
          dateTimeToSql(entity.createdAt),
          dateTimeToSql(entity.updatedAt),
          transactionDirectionToSql(entity.direction) ?? 'unknown',
          serverId,
          now,
          dateTimeToSql(entity.updatedAt),
        ],
      );
      await clearFinancialCacheDirty(_db, transactionsCacheEntityType);
    } catch (e) {
      await markFinancialCacheDirty(_db, transactionsCacheEntityType, e);
    }
  }

  Future<void> _mirrorDeleteByServerId(String serverId) async {
    try {
      final localId = await _localIdForServerId(serverId);
      if (localId == null) return;
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement(
        '''
          UPDATE transactions
          SET status = 'ignored', synced_at = ?, sync_status = 'synced'
          WHERE id = ?;
        ''',
        [now, localId],
      );
      await clearFinancialCacheDirty(_db, transactionsCacheEntityType);
    } catch (e) {
      await markFinancialCacheDirty(_db, transactionsCacheEntityType, e);
    }
  }
}
