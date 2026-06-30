abstract class DedupStore {
  /// Returns the transaction ID of a prior transaction with the same hash and
  /// exact comparison timestamp, or null if none.
  Future<String?> transactionIdFor(String hash, DateTime occurredAt);

  /// Records a hash after a successful save, keyed by the comparison timestamp.
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  });
}
