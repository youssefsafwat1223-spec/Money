import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../engine/parser/card_network.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftTransactionRepository implements TransactionRepository {
  DriftTransactionRepository(this._db);

  final AppDatabase _db;

  @override
  Future<TransactionEntity> confirm(String id) async {
    await _db.customUpdate(
      '''
        UPDATE transactions
        SET status = 'confirmed', updated_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(id),
      ],
    );

    final updated = await getById(id);
    if (updated == null) {
      throw StateError('Transaction not found: $id');
    }
    return updated;
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async {
    final merchantId = await _merchantIdByRawName(rawMerchant);
    if (merchantId == null) {
      return null;
    }

    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM transactions
        WHERE merchant_id = ?
          AND amount = ?
          AND occurred_at BETWEEN ? AND ?
        ORDER BY occurred_at DESC
        LIMIT 1;
      ''',
      variables: [
        Variable.withString(merchantId),
        Variable.withReal(amount),
        Variable.withString(dateTimeToSql(
            occurredAt.toUtc().subtract(const Duration(minutes: 2)))),
        Variable.withString(
            dateTimeToSql(occurredAt.toUtc().add(const Duration(minutes: 2)))),
      ],
    ).getSingleOrNull();

    return rows == null ? null : transactionFromRow(rows);
  }

  @override
  Future<TransactionEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM transactions WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : transactionFromRow(row);
  }

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) async {
    final merchantId = transaction.rawMerchant == null
        ? null
        : await _resolveOrCreateMerchantId(transaction.rawMerchant!);
    final categoryId =
        categoryKey == null ? null : await _categoryIdByKey(categoryKey);

    await _db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, merchant_id, raw_merchant, category_id, type, source,
        card_last4, balance_after, occurred_at, raw_message, parse_confidence, status,
        created_at, updated_at
      ) VALUES (
        ${sqlString(transaction.id)},
        ${transaction.amount},
        ${sqlString(transaction.currency)},
        ${sqlNullableString(merchantId)},
        ${sqlNullableString(transaction.rawMerchant)},
        ${sqlNullableString(categoryId)},
        ${sqlString(transaction.type.name)},
        ${sqlString(transaction.source.name)},
        ${sqlNullableString(transaction.cardLast4)},
        ${sqlNullableNum(transaction.balanceAfter)},
        ${sqlString(dateTimeToSql(transaction.occurredAt))},
        ${sqlString(transaction.rawMessage)},
        ${transaction.parseConfidence},
        ${sqlString(transaction.status.name)},
        ${sqlString(dateTimeToSql(transaction.createdAt))},
        ${sqlString(dateTimeToSql(transaction.updatedAt))}
      );
    ''');

    final saved = await getById(transaction.id);
    if (saved == null) {
      throw StateError('Failed to load saved transaction: ${transaction.id}');
    }
    return saved;
  }

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) async {
    final categoryId = await _categoryIdByKey(categoryKey);
    if (categoryId == null) {
      throw StateError('Unknown category key: $categoryKey');
    }

    await _db.customUpdate(
      '''
        UPDATE transactions
        SET category_id = ?, status = 'confirmed', updated_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(categoryId),
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(transactionId),
      ],
    );

    final updated = await getById(transactionId);
    if (updated == null) {
      throw StateError('Transaction not found: $transactionId');
    }
    return updated;
  }

  @override
  Future<List<TransactionEntity>> getRecent({int limit = 5}) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status != 'ignored'
        ORDER BY occurred_at DESC
        LIMIT ?;
      ''',
      variables: [Variable.withInt(limit)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<TransactionEntity>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status != 'ignored'
        ORDER BY occurred_at DESC;
      ''',
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final row = await _db.customSelect(
      '''
        SELECT CAST(COALESCE(SUM(amount), 0) AS REAL) AS total
        FROM transactions
        WHERE type IN ('payment', 'withdrawal')
          AND status != 'ignored'
          AND occurred_at BETWEEN ? AND ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).getSingle();
    return row.read<double>('total');
  }

  @override
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final row = await _db.customSelect(
      '''
        SELECT CAST(COALESCE(SUM(amount), 0) AS REAL) AS total
        FROM transactions
        WHERE type = 'income'
          AND status != 'ignored'
          AND occurred_at BETWEEN ? AND ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).getSingle();
    return row.read<double>('total');
  }

  @override
  Future<double?> latestBalanceAfter() async {
    final row = await _db.customSelect(
      '''
        SELECT CAST(balance_after AS REAL) AS balance
        FROM transactions
        WHERE status != 'ignored'
          AND balance_after IS NOT NULL
        ORDER BY occurred_at DESC
        LIMIT 1;
      ''',
    ).getSingleOrNull();
    return row?.read<double>('balance');
  }

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT date(occurred_at) AS day, CAST(COALESCE(SUM(amount), 0) AS REAL) AS total
        FROM transactions
        WHERE type IN ('payment', 'withdrawal')
          AND status != 'ignored'
          AND occurred_at BETWEEN ? AND ?
        GROUP BY date(occurred_at)
        ORDER BY day ASC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).get();
    return rows
        .map(
          (r) => DailySpend(
            day: DateTime.parse(r.read<String>('day')),
            total: r.read<double>('total'),
          ),
        )
        .toList();
  }

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT category_id AS cid, CAST(SUM(amount) AS REAL) AS total
        FROM transactions
        WHERE type IN ('payment', 'withdrawal')
          AND status != 'ignored'
          AND category_id IS NOT NULL
          AND occurred_at BETWEEN ? AND ?
        GROUP BY category_id
        ORDER BY total DESC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).get();
    return rows
        .map(
          (r) => CategorySpend(
            categoryId: r.read<String>('cid'),
            total: r.read<double>('total'),
          ),
        )
        .toList();
  }

  @override
  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
  }) async {
    final row = await _db.customSelect(
      '''
        SELECT CAST(COALESCE(SUM(
          CASE
            WHEN type = 'refund' THEN -amount
            ELSE amount
          END
        ), 0) AS REAL) AS total
        FROM transactions
        WHERE status != 'ignored'
          AND category_id = ?
          AND type IN ('payment', 'withdrawal', 'refund')
          AND occurred_at BETWEEN ? AND ?;
      ''',
      variables: [
        Variable.withString(categoryId),
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).getSingle();
    return row.read<double>('total');
  }

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT m.raw_name AS name, CAST(SUM(t.amount) AS REAL) AS total
        FROM transactions t
        INNER JOIN merchants m ON m.id = t.merchant_id
        WHERE t.type IN ('payment', 'withdrawal')
          AND t.status != 'ignored'
          AND t.occurred_at BETWEEN ? AND ?
        GROUP BY t.merchant_id
        ORDER BY total DESC
        LIMIT ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        Variable.withInt(limit),
      ],
    ).get();
    return rows
        .map((r) => MerchantSpend(
              name: r.read<String>('name'),
              total: r.read<double>('total'),
            ))
        .toList();
  }

  @override
  Future<List<CardSummary>> getCardSummaries() async {
    final rows = await _db.customSelect(
      '''
        SELECT card_last4 AS last4,
               CAST(SUM(CASE WHEN type IN ('payment','withdrawal') THEN amount ELSE 0 END) AS REAL) AS out_total,
               CAST(SUM(CASE WHEN type IN ('income','refund') THEN amount ELSE 0 END) AS REAL) AS in_total,
               COUNT(*) AS cnt,
               MAX(raw_message) AS sample
        FROM transactions
        WHERE card_last4 IS NOT NULL AND status != 'ignored'
        GROUP BY card_last4
        ORDER BY (out_total + in_total) DESC;
      ''',
    ).get();
    return rows
        .map((r) => CardSummary(
              last4: r.read<String>('last4'),
              network: CardNetworkDetector.detect(
                  r.readNullable<String>('sample') ?? ''),
              totalOut: r.read<double>('out_total'),
              totalIn: r.read<double>('in_total'),
              count: r.read<int>('cnt'),
            ))
        .toList();
  }

  @override
  Future<List<TransactionEntity>> getByCard(String last4) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE card_last4 = ? AND status != 'ignored'
        ORDER BY occurred_at DESC;
      ''',
      variables: [Variable.withString(last4)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<RecurringCandidate>> recurringCandidates() async {
    final rows = await _db.customSelect(
      '''
        SELECT mid, name, avg_amount, months FROM (
          SELECT m.id AS mid, m.raw_name AS name,
                 CAST(AVG(t.amount) AS REAL) AS avg_amount,
                 CAST(MIN(t.amount) AS REAL) AS min_a,
                 CAST(MAX(t.amount) AS REAL) AS max_a,
                 CAST(COUNT(DISTINCT strftime('%Y-%m', t.occurred_at)) AS INTEGER) AS months
          FROM transactions t
          INNER JOIN merchants m ON m.id = t.merchant_id
          WHERE t.type = 'payment' AND t.status != 'ignored'
          GROUP BY t.merchant_id
        )
        WHERE months >= 2 AND (max_a - min_a) <= (avg_amount * 0.15)
        ORDER BY avg_amount DESC;
      ''',
    ).get();
    return rows
        .map((r) => RecurringCandidate(
              merchantId: r.read<String>('mid'),
              name: r.read<String>('name'),
              averageAmount: r.read<double>('avg_amount'),
              monthsSeen: r.read<int>('months'),
            ))
        .toList();
  }

  Future<String?> _categoryIdByKey(String categoryKey) async {
    final row = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(categoryKey)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String?> _merchantIdByRawName(String rawMerchant) async {
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    final row = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String> _resolveOrCreateMerchantId(String rawMerchant) async {
    final existing = await _merchantIdByRawName(rawMerchant);
    final now = dateTimeToSql(DateTime.now().toUtc());
    if (existing != null) {
      await _db.customUpdate(
        'UPDATE merchants SET last_seen_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(now),
          Variable.withString(existing),
        ],
      );
      return existing;
    }

    final merchantId = IdGenerator.next();
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    await _db.customInsert(
      '''
        INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(merchantId),
        Variable.withString(rawMerchant),
        Variable.withString(normalized),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
    return merchantId;
  }
}
