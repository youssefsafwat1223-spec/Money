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

/// Offline- and ownership-aware gate for background sync (MALI-029 cadence). Pure
/// and deterministic — no clock/random/connectivity of its own — so the full
/// offline → recovery → sign-out/ownership contract is unit-tested with an
/// injected connectivity signal and a fake clock at the call site.
///
/// The app has no platform connectivity source, so "offline" is inferred from
/// the sync run itself: a completed attempt whose push outbox is left
/// network-stalled reports `reachedNetwork: false`. This ONLY paces/gates
/// triggering; it never changes sync authority, ordering, revision, or conflict
/// semantics.
class SyncGate {
  int _generation = 0;
  bool _online = true;
  bool _pendingIntent = false;

  /// The current owner generation. Any run/intent captured under a prior
  /// generation is stale (a different — or signed-out — owner).
  int get generation => _generation;

  /// Whether the gate currently believes the network is reachable.
  bool get isOnline => _online;

  /// Whether a single coalesced sync intent is queued (offline or a suppressed
  /// local-activity trigger) awaiting the next admissible run.
  bool get hasPendingIntent => _pendingIntent;

  /// Sign-out / owner change: bump the generation so any run/intent captured
  /// under the old generation is no longer admitted, drop the queued intent so
  /// old-owner work can never execute under a new owner, and reset to optimistic
  /// online (a fresh owner must not inherit the previous owner's offline state).
  /// Returns the new generation.
  int invalidate() {
    _pendingIntent = false;
    _online = true;
    return ++_generation;
  }

  /// A run/intent captured at [generation] is admitted only while its generation
  /// is still current — the guard that stops an old-owner (or pre-sign-out) run
  /// from writing under a new owner.
  bool admits(int generation) => generation == _generation;

  /// Whether a trigger should run the sync body now.
  /// - [manual] (user/manual) always runs — priority over backoff/offline.
  /// - [recoveryProbe] (resume/periodic poll) always runs so connectivity can be
  ///   re-detected; it is the sole auto-recovery path while offline.
  /// - a plain background trigger (e.g. a local-activity wakeup) runs while
  ///   online; while offline it does NOT run (no doomed remote work / retry
  ///   burn) and instead coalesces exactly ONE pending intent.
  bool shouldRun({bool manual = false, bool recoveryProbe = false}) {
    if (manual || recoveryProbe || _online) {
      _pendingIntent = false;
      return true;
    }
    _pendingIntent = true;
    return false;
  }

  /// Record a completed attempt's reachability.
  /// - not reached → go offline and keep exactly one pending intent so the work
  ///   is retried once connectivity returns (never one-per-missed-timer).
  /// - reached → go online; returns true exactly once when a pending intent was
  ///   waiting (queued while offline) so the caller fires a single recovery sync.
  bool recordReachability({required bool reachedNetwork}) {
    if (!reachedNetwork) {
      _online = false;
      _pendingIntent = true;
      return false;
    }
    final recover = _pendingIntent;
    _online = true;
    _pendingIntent = false;
    return recover;
  }
}
