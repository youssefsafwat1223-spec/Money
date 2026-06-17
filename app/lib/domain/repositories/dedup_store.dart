abstract class DedupStore {
  /// Returns the transaction ID of a prior transaction with the same hash
  /// that occurred within ±5 minutes of [occurredAt], or null if none.
  Future<String?> transactionIdFor(String hash, DateTime occurredAt);

  /// Records a hash after a successful save, keyed by [occurredAt] for the
  /// sliding-window lookup.
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  });
}
