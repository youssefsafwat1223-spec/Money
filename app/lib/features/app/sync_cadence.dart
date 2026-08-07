// Phase-7 Batch-2 (MALI-029 cadence) — pure, deterministic sync-cadence policy.
//
// Extracted from AppShell so the backoff/coalescing decisions are unit-testable
// without timers or widgets. This ONLY paces polling and coalesces overlapping
// requests; it does NOT change sync authority, ordering, or conflict semantics.
class SyncCadence {
  SyncCadence({
    this.base = const Duration(seconds: 30),
    this.max = const Duration(seconds: 300),
  });

  /// Poll interval when there is recent activity.
  final Duration base;

  /// Ceiling the interval backs off to when repeatedly idle/offline.
  final Duration max;

  int _idleStreak = 0;

  /// A completed periodic poll that found nothing to do (or could not reach the
  /// network) — widen the next interval so an idle/offline app does not poll (and
  /// burn retries) every [base].
  void recordIdlePoll() => _idleStreak++;

  /// Local activity or a successful sync that made progress — return to [base] so
  /// the app stays responsive.
  void recordActivity() => _idleStreak = 0;

  /// A user/manual-triggered sync always takes priority over backoff.
  void recordUserTriggered() => _idleStreak = 0;

  /// Consecutive idle polls (diagnostic / test).
  int get idleStreak => _idleStreak;

  /// Next poll delay: [base], doubling per consecutive idle poll, capped at [max].
  /// Deterministic (no wall-clock/random) so it is fully testable.
  Duration nextDelay() {
    if (_idleStreak <= 0) return base;
    final shift = _idleStreak.clamp(1, 16);
    final factor = 1 << shift; // 2, 4, 8, ...
    final ms = base.inMilliseconds * factor;
    return ms >= max.inMilliseconds ? max : Duration(milliseconds: ms);
  }
}

/// Coalesces overlapping run requests into at most ONE pending follow-up: a
/// request that arrives while a run is in flight is remembered, and exactly one
/// extra run fires afterward (never a queue of duplicates). Pure state machine —
/// the caller drives the actual async run.
class SyncCoalescer {
  bool _running = false;
  bool _pending = false;

  bool get isRunning => _running;

  /// Call when a run is requested. Returns true if the caller should START a run
  /// now; false if a run is already in flight (the request is coalesced into a
  /// single pending follow-up).
  bool requestRun() {
    if (_running) {
      _pending = true;
      return false;
    }
    _running = true;
    return true;
  }

  /// Call when a run finishes. Returns true if a coalesced request arrived during
  /// the run and the caller should START exactly one more run now.
  bool finishRun() {
    _running = false;
    if (_pending) {
      _pending = false;
      _running = true;
      return true;
    }
    return false;
  }
}
