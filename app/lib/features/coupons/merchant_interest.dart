import '../../domain/entities/report_models.dart';
import 'merchant_lookup_pipeline.dart';

/// How interesting a merchant is to this user, derived from THIS DEVICE'S ledger.
///
/// ## This type must never be serialised to a network payload
///
/// A merchant-interest score is a direct statement about someone's spending:
/// "this person shops at X, often, recently". Sending it anywhere would hand a
/// server a behavioural profile assembled from bank messages — the single most
/// sensitive derivative this app produces, and the thing the whole
/// on-device-personalization decision exists to prevent.
///
/// So it is deliberately a plain value object with no `toJson`, no `toMap` and
/// no codec. `coupons_isolation_test.dart` asserts that no coupon file reaches
/// the network with one, and `egress_inventory_test.dart` classifies every call
/// site. If you find yourself adding serialisation here, the design has gone
/// wrong somewhere upstream.
class MerchantInterest {
  const MerchantInterest({
    required this.merchantId,
    required this.score,
    required this.transactionCount,
  });

  final String merchantId;

  /// 0.0 – 1.0, relative to the strongest merchant in the same window. A
  /// relative score, never an amount: the ranking only needs an order, and an
  /// absolute figure would be a spending disclosure sitting in memory for no
  /// benefit.
  final double score;

  final int transactionCount;
}

/// Builds interest scores from local spend aggregates.
///
/// Pure and synchronous — it takes prepared inputs and does no I/O, so it can be
/// called from a provider without touching the database on every frame, and so
/// its behaviour is fully testable without a database at all.
class MerchantInterestScorer {
  const MerchantInterestScorer._();

  /// Minimum transactions at a merchant before it counts as interest.
  ///
  /// One purchase is not a habit. Below this the signal is mostly noise, and
  /// acting on it produces the "you shop here!" message about a place someone
  /// visited once — the exact failure that makes personalization feel invasive
  /// rather than useful.
  static const int minimumTransactions = 2;

  /// Score the user's merchants.
  ///
  /// [spend] is the local `merchantBreakdown` result; [resolve] maps each raw
  /// merchant label to a canonical merchant, and returns null when it abstains.
  /// Unresolved merchants are DROPPED, not bucketed: an abstention means we do
  /// not know who this is, and inventing a bucket for them would put unrelated
  /// spending under one heading.
  static List<MerchantInterest> score(
    List<MerchantSpend> spend,
    String? Function(String rawMerchantName) resolve,
  ) {
    // Several raw labels can resolve to one merchant — "NOON", "NOON KSA" and
    // "noon.com" are one company — so totals are merged BEFORE ranking. Ranking
    // first would let one company appear three times and crowd out the rest.
    final counts = <String, int>{};
    final weights = <String, double>{};

    for (final row in spend) {
      final merchantId = resolve(row.name);
      if (merchantId == null) continue;
      counts[merchantId] = (counts[merchantId] ?? 0) + (row.count == 0 ? 1 : row.count);
      // Frequency, not amount. Someone who buys coffee daily is more interested
      // in a coffee offer than someone who bought one expensive thing once, and
      // frequency is also far less sensitive to hold in memory than a total.
      weights[merchantId] =
          (weights[merchantId] ?? 0) + (row.count == 0 ? 1 : row.count).toDouble();
    }

    final eligible = counts.entries
        .where((e) => e.value >= minimumTransactions)
        .map((e) => e.key)
        .toList();
    if (eligible.isEmpty) return const [];

    final max = eligible
        .map((id) => weights[id] ?? 0)
        .fold<double>(0, (a, b) => a > b ? a : b);
    if (max <= 0) return const [];

    final out = eligible
        .map((id) => MerchantInterest(
              merchantId: id,
              score: (weights[id] ?? 0) / max,
              transactionCount: counts[id] ?? 0,
            ))
        .toList();

    // Deterministic: score desc, then count desc, then id — so the same ledger
    // always produces the same order and the UI never flickers between builds.
    out.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byCount = b.transactionCount.compareTo(a.transactionCount);
      if (byCount != 0) return byCount;
      return a.merchantId.compareTo(b.merchantId);
    });
    return List<MerchantInterest>.unmodifiable(out);
  }

  /// Convenience for the common case: score against a resolver that has already
  /// produced [MerchantMatch]es, dropping every abstention.
  static List<MerchantInterest> fromMatches(
    List<MerchantSpend> spend,
    Map<String, MerchantMatch> matches,
  ) =>
      score(spend, (name) {
        final m = matches[name];
        return m != null && m.isResolved ? m.merchantId : null;
      });
}
