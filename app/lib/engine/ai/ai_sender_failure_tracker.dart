/// Tracks consecutive grounding failures per SMS sender.
///
/// After [_suppressAfter] consecutive failures for the same senderId,
/// the sender is suppressed for the lifetime of the app session. A single
/// successful grounding check resets the counter.
///
/// In-memory only — resets on app restart. Persistent suppression is not
/// needed because grounding failures should be rare; the goal is preventing
/// runaway API spend from a single broken sender in one session.
class AiSenderFailureTracker {
  AiSenderFailureTracker._();

  static final instance = AiSenderFailureTracker._();

  static const _suppressAfter = 3;
  final _counts = <String, int>{};

  bool isSuppressed(String senderId) {
    final key = senderId.trim();
    if (key.isEmpty) return false;
    return (_counts[key] ?? 0) >= _suppressAfter;
  }

  void recordFailure(String senderId) {
    final key = senderId.trim();
    if (key.isEmpty) return;
    _counts[key] = (_counts[key] ?? 0) + 1;
  }

  void recordSuccess(String senderId) {
    final key = senderId.trim();
    if (key.isEmpty) return;
    _counts.remove(key);
  }

  void resetForTest() => _counts.clear();
}
