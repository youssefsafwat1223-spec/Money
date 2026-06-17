import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Computes a dedup hash for a parsed transaction.
///
/// The hash covers time-invariant fields only: amount, currency, card, merchant,
/// and type. The time-window check (±5 min) is enforced at query time in
/// [DriftDedupStore], so there are no fixed-bucket boundary misses.
///
/// Two distinct transactions with the same amount but different merchants → different
/// hashes, even within the same minute.
class TransactionDedup {
  TransactionDedup._();

  static final _sha = Sha256();

  /// [merchantNormalized] should be upper-case, digits stripped (use
  /// [AppDatabase.normalizeMerchant] or equivalent). Pass null for no-merchant
  /// transactions (transfers, ATM withdrawals).
  ///
  /// [type] is the transaction type string (e.g. `TransactionType.payment.name`).
  static Future<String> computeHash({
    required double amount,
    required String currency,
    String? cardLast4,
    String? merchantNormalized,
    required String type,
  }) async {
    final key =
        '$amount|${currency.toUpperCase()}|${cardLast4 ?? ''}|${merchantNormalized?.toUpperCase() ?? ''}|$type';
    final bytes = utf8.encode(key);
    final digest = await _sha.hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Normalizes a raw merchant name for inclusion in the hash key.
  /// Strips digits and collapses whitespace, matching AppDatabase.normalizeMerchant.
  static String normalizeMerchant(String rawMerchant) {
    return rawMerchant
        .toUpperCase()
        .replaceAll(RegExp(r'[0-9]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
