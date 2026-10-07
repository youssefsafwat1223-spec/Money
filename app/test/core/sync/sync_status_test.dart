import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/sync/sync_status.dart';

final _t0 = DateTime.utc(2026, 6, 1, 10);
final _t1 = DateTime.utc(2026, 6, 1, 11);

Map<SyncDomain, SyncDomainHealth> _health({DateTime? push, DateTime? pull}) => {
      for (final d in SyncDomain.values)
        d: SyncDomainHealth(lastPushSuccessAt: push, lastPullSuccessAt: pull),
    };

SyncStatus _derive({
  SyncQueueCounts counts = const SyncQueueCounts(),
  Map<SyncDomain, SyncDomainHealth>? health,
  bool consent = true,
  SyncIdentity identity = SyncIdentity.authenticated,
  bool running = false,
}) =>
    SyncStatus.derive(
      counts: counts,
      health: health ?? _health(push: _t1),
      cloudConsent: consent,
      identity: identity,
      syncRunning: running,
    );

void main() {
  group('SyncStatus truth table', () {
    test('clean queue + push after last mutation -> allSynced', () {
      final s = _derive(counts: SyncQueueCounts(lastLocalMutationAt: _t0));
      expect(s.kind, SyncStatusKind.allSynced);
      expect(s.lastSuccessAt, _t1);
    });

    test('nothing ever queued -> allSynced', () {
      expect(_derive(health: _health()).kind, SyncStatusKind.allSynced);
    });

    test('push OLDER than the last local mutation is not allSynced', () {
      final s = _derive(
        counts: SyncQueueCounts(lastLocalMutationAt: _t1),
        health: _health(push: _t0),
      );
      expect(s.kind, isNot(SyncStatusKind.allSynced));
      // WP-8: "Syncing…" lasts one active run; idle + unproven is waiting.
      expect(s.kind, SyncStatusKind.waiting);
    });

    test('a mutation with no push success at all is not allSynced', () {
      final s = _derive(
        counts: SyncQueueCounts(lastLocalMutationAt: _t0),
        health: _health(),
      );
      expect(s.kind, isNot(SyncStatusKind.allSynced));
    });

    test('a sync run in progress -> syncing', () {
      expect(_derive(running: true).kind, SyncStatusKind.syncing);
    });

    test('pending rows -> waiting(n)', () {
      final s = _derive(counts: const SyncQueueCounts(pending: 3));
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 3);
      expect(s.waitingForConnection, 3);
    });

    test('parked rows split into connection vs server-update waits', () {
      final s = _derive(
        counts: const SyncQueueCounts(
          pending: 1,
          parked: 3,
          parkedByReason: {
            kParkAwaitingServerFxSupport: 2,
            kParkDependencyWait: 1,
          },
        ),
      );
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 4);
      expect(s.waitingForServer, 2);
      expect(s.waitingForConnection, 2);
    });

    test('auth-parked rows are waiting, never allSynced', () {
      final s = _derive(
        counts: const SyncQueueCounts(
            parked: 2, parkedByReason: {kParkAuthRequired: 2}),
      );
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 2);
    });

    test('in-flight row alone is waiting', () {
      final s = _derive(counts: const SyncQueueCounts(inFlight: 1));
      expect(s.kind, SyncStatusKind.waiting);
    });

    test('dead letters -> failed(n), with stay-failed ones listed', () {
      final s = _derive(
        counts: const SyncQueueCounts(deadLetter: 3, deadLetterByReason: {
          kFailDuplicateBusinessKey: 1,
          kFailUnsupportedOperation: 1,
          'serverError': 1,
        }),
      );
      expect(s.kind, SyncStatusKind.failed);
      expect(s.count, 3);
      expect(s.needsAttention, 3);
      expect(s.stayFailed, 2);
    });

    test('failed outranks syncing and waiting', () {
      final s = _derive(
        counts: const SyncQueueCounts(pending: 4, deadLetter: 1),
        running: true,
      );
      expect(s.kind, SyncStatusKind.failed);
    });

    test('terminal sender mapping failure -> failed', () {
      final s = _derive(
        counts: const SyncQueueCounts(
            senderMappingsFailed: 1, senderMappingsPermanentFailed: 1),
      );
      expect(s.kind, SyncStatusKind.failed);
    });

    test('retrying (non-terminal) sender mapping failure is waiting', () {
      final s = _derive(
        counts: const SyncQueueCounts(senderMappingsFailed: 2),
      );
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 2);
    });

    test('smart-inbox / sender-mapping pending count as waiting', () {
      final s = _derive(
        counts: const SyncQueueCounts(
            smartInboxPendingSync: 1, senderMappingsPending: 1),
      );
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 2);
    });

    test('consent off -> consentOff with the kept count, even if clean', () {
      final clean = _derive(consent: false);
      expect(clean.kind, SyncStatusKind.consentOff);
      final kept = _derive(
        consent: false,
        counts: const SyncQueueCounts(pending: 2, parked: 1, deadLetter: 1),
      );
      expect(kept.kind, SyncStatusKind.consentOff);
      expect(kept.count, 4);
    });

    test('guest / signed out -> signedOut regardless of consent', () {
      for (final id in [SyncIdentity.guest, SyncIdentity.signedOut]) {
        for (final consent in [true, false]) {
          expect(_derive(identity: id, consent: consent).kind,
              SyncStatusKind.signedOut);
        }
      }
    });

    test('NEVER allSynced while any outbox row exists or consent is off', () {
      const rowShapes = <SyncQueueCounts>[
        SyncQueueCounts(pending: 1),
        SyncQueueCounts(parked: 1, parkedByReason: {kParkOwnerMismatch: 1}),
        SyncQueueCounts(deadLetter: 1),
        SyncQueueCounts(inFlight: 1),
        SyncQueueCounts(senderMappingsPending: 1),
        SyncQueueCounts(smartInboxPendingSync: 1),
      ];
      for (final counts in rowShapes) {
        for (final running in [true, false]) {
          for (final consent in [true, false]) {
            for (final id in SyncIdentity.values) {
              final s = _derive(
                  counts: counts,
                  running: running,
                  consent: consent,
                  identity: id);
              expect(s.kind, isNot(SyncStatusKind.allSynced),
                  reason: '$counts running=$running consent=$consent $id');
            }
          }
        }
      }
      for (final running in [true, false]) {
        expect(_derive(consent: false, running: running).kind,
            isNot(SyncStatusKind.allSynced));
      }
    });
  });

  group('SyncHealth.queueCounts (A-5 fields)', () {
    // Covered against a real database in sync_recovery_test.dart.
    test('defaults are empty', () {
      const c = SyncQueueCounts();
      expect(c.deadLetterByReason, isEmpty);
      expect(c.inFlight, 0);
      expect(c.lastLocalMutationAt, isNull);
    });
  });

  group('offline truth beats a run in progress', () {
    Map<SyncDomain, SyncDomainHealth> offlineHealth(int fails) => {
          for (final d in SyncDomain.values)
            d: SyncDomainHealth(
              lastPushSuccessAt: _t0,
              lastErrorClass: SyncErrorClass.offline,
              consecutiveFailures: fails,
            ),
        };

    test('running + network-stalled pending rows -> waiting(n), not syncing',
        () {
      final s = _derive(
        counts: const SyncQueueCounts(pending: 2, networkStalled: 2),
        running: true,
      );
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 2);
      expect(s.waitingForConnection, 2);
    });

    test('running + latest outbox attempt failed offline -> waiting(n)', () {
      final s = _derive(
        counts: const SyncQueueCounts(pending: 1),
        health: offlineHealth(2),
        running: true,
      );
      expect(s.kind, SyncStatusKind.waiting);
    });

    test('observed sequence: repeated failing runs never leave it syncing', () {
      for (var attempt = 1; attempt <= 3; attempt++) {
        final s = _derive(
          counts: const SyncQueueCounts(pending: 1, networkStalled: 1),
          health: offlineHealth(attempt),
          running: true,
        );
        expect(s.kind, SyncStatusKind.waiting, reason: 'attempt $attempt');
      }
    });

    test('running with healthy network and queued work stays syncing', () {
      expect(
        _derive(counts: const SyncQueueCounts(pending: 1), running: true).kind,
        SyncStatusKind.syncing,
      );
    });

    test('stale offline error with no queued work is never waiting/allSynced '
        'regressions', () {
      final s = _derive(health: {
        for (final d in SyncDomain.values)
          d: SyncDomainHealth(
            lastPushSuccessAt: _t1,
            lastErrorClass: SyncErrorClass.offline,
            consecutiveFailures: 3,
          ),
      });
      expect(s.kind, SyncStatusKind.allSynced);
    });
  });

  test('SyncRunState is counted and notifies on the edges only', () {
    final state = SyncRunState.instance;
    var notes = 0;
    void l() => notes++;
    state.addListener(l);
    expect(state.running, isFalse);
    state.begin();
    state.begin();
    expect(state.running, isTrue);
    state.end();
    expect(state.running, isTrue);
    state.end();
    expect(state.running, isFalse);
    state.end(); // underflow is a no-op
    expect(state.running, isFalse);
    expect(notes, 2);
    state.removeListener(l);
  });
}
