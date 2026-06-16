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

  bool isSuppressed(String senderId) =>
      (_counts[senderId] ?? 0) >= _suppressAfter;

  void recordFailure(String senderId) =>
      _counts[senderId] = (_counts[senderId] ?? 0) + 1;

  void recordSuccess(String senderId) => _counts.remove(senderId);

  void resetForTest() => _counts.clear();
}
