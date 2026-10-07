import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/finance/money_transport.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';

/// Cross-model audit **H-4** — capability authority vs. actual transport.
///
/// Three capabilities ship `unknown` (`exactPush`, `exactPull`,
/// `planningServerCurrency`) yet several money-bearing paths never consulted
/// them:
///
///   * accounts pull and ledger pull were wired `() => true` — there was NO
///     seam through which an explicitly `unsupported` transport could turn them
///     off, so the "explicit false must disable" rule was unimplementable.
///   * every non-planning entity short-circuited the planning pull gate.
///   * the startup backfills — a PUSH path that serializes canonical money as
///     exact decimal strings — bypassed `shouldParkExactMoneyWrite` entirely,
///     which under Batch 5 let an unauthorised transport mark rows `synced` and
///     report `ran` (proven-complete).
///
/// The invariant: an UNKNOWN capability must never silently become ENABLED
/// authority, and financial transport must fail closed where it cannot verify
/// itself.
const _canonical = PlanningCutoverState.canonical;

void main() {
  group('H-4 — PUSH: unverified transport is parked', () {
    test('canonical + unknown ⇒ parked', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.unknown,
        ),
        isTrue,
      );
    });

    test('canonical + unsupported ⇒ parked', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.unsupported,
        ),
        isTrue,
      );
    });

    test('canonical + verifiedExact ⇒ allowed (positive proof enables)', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.verifiedExact,
        ),
        isFalse,
      );
    });
  });

  group('H-4 — PULL authority is positive-proof only', () {
    test('UNKNOWN blocks pull', () {
      // The decisive rule: an unverified transport is not an authorised one.
      // Decoder strictness proves PAYLOAD safety, never TRANSPORT authority.
      expect(exactPullAllowed(ExactTransportCapability.unknown), isFalse,
          reason: 'unknown must fail closed — only positive proof may enable a '
              'financial transport');
    });

    test('UNSUPPORTED blocks pull', () {
      expect(exactPullAllowed(ExactTransportCapability.unsupported), isFalse);
    });

    test('verifiedExact allows pull', () {
      expect(exactPullAllowed(ExactTransportCapability.verifiedExact), isTrue);
    });

    test('push and pull are SYMMETRIC in authority', () {
      // Same capability value ⇒ same verdict in both directions.
      for (final cap in const [
        ExactTransportCapability.unknown,
        ExactTransportCapability.unsupported,
      ]) {
        expect(exactPullAllowed(cap), isFalse, reason: '$cap pull');
        expect(
          shouldParkExactMoneyWrite(
              cutoverState: _canonical, pushCapability: cap),
          isTrue,
          reason: '$cap push',
        );
      }
      expect(exactPullAllowed(ExactTransportCapability.verifiedExact), isTrue);
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.verifiedExact,
        ),
        isFalse,
      );
    });

    test('decoder strictness remains, as DEFENCE — not as authority', () {
      // Still valuable, still asserted: a non-`::text` payload is refused
      // rather than degraded to a double. But it may never substitute for
      // positive capability authority (requirement 9).
      expect(
        () => moneyFromPulledValue(12.34, 'SAR'),
        throwsA(isA<MoneyTransportException>()),
      );
      expect(
        () => moneyFromPulledValue(1234, 'SAR'),
        throwsA(isA<MoneyTransportException>()),
      );
      expect(moneyFromPulledValue('12.345', 'KWD')!.minorUnits, 12345);
      expect(moneyFromPulledValue(null, 'SAR'), isNull);

      // …and it does NOT unlock the gate.
      expect(exactPullAllowed(ExactTransportCapability.unknown), isFalse,
          reason: 'a strict decoder must never be treated as proof of '
              'transport authority');
    });
  });

  group('H-4 — the Smart Inbox exemption stays justified', () {
    test('smart inbox sync carries no exact-money transport', () {
      // It is the ONE pull deliberately left outside the money gate. That is
      // only correct while it moves no money — if it ever gains a money column
      // this fails, and the exemption must be revisited rather than inherited.
      final source = File(
        'lib/features/capture/services/smart_inbox_sync_service.dart',
      ).readAsStringSync();
      for (final marker in const [
        'moneyFromPulledValue',
        '::text',
        'kMoneyCodec',
        '_minor',
        'Money',
      ]) {
        expect(source.contains(marker), isFalse,
            reason: 'smart inbox now touches money ("$marker") — it can no '
                'longer be exempt from the exact-transport capability gate');
      }
    });
  });

  group('H-4 — startup races are structurally absent, not merely unobserved',
      () {
    final source =
        File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();

    test('exact push/pull are synchronous build constants — nothing to race with',
        () {
      // Exact push/pull are PostgREST/Postgres type semantics, proven against a
      // real local PostgREST (local-Supabase suite S2/S3/S4) and shipped as plain
      // synchronous Providers returning a constant — resolved identically on the
      // very first read, before any startup step runs.
      for (final name in const [
        'exactPushTransportCapabilityProvider',
        'exactPullTransportCapabilityProvider',
      ]) {
        final start = source.indexOf('final $name');
        final body = source.substring(start, source.indexOf('\n});', start));
        expect(body, contains('Provider<ExactTransportCapability>'),
            reason: '$name must stay synchronous');
        for (final async in const ['Future', 'async', 'await', 'StateNotifier']) {
          expect(body.contains(async), isFalse,
              reason: '$name must not gain an async/mutable path without a '
                  'race review: found "$async"');
        }
      }
    });

    test('planning currency is the ONLY runtime-discovered capability, and the '
        'holder itself never probes', () {
      // 0077 deployment state is unknown at build time, so its capability is a
      // runtime probe result held in a Notifier that starts `unknown` and is
      // only moved by PlanningCurrencyCapabilityProbe. The holder has no I/O.
      final start =
          source.indexOf('class PlanningServerCurrencyCapabilityNotifier');
      final end = source.indexOf('final planningServerCurrencyCapabilityProvider');
      final body = source.substring(start, end);
      expect(body, contains('ExactTransportCapability.unknown'));
      for (final io in const ['Future', 'async', 'await', 'supabase']) {
        expect(body.contains(io), isFalse,
            reason: 'the capability holder must not do I/O itself: "$io"');
      }
    });

    test('activation requires a reviewed code change, not a runtime toggle', () {
      // This is the SAFE property, not a gap to be closed with a flag: a
      // financial transport can only be declared proven by shipping code.
      expect(source.contains('FeatureFlagService'), isFalse);
      expect(source.contains('SharedPreferences'), isFalse);
      expect(source.contains('remoteConfig'), isFalse);
    });

    test('revision CAS is a server capability, never a client constant', () {
      // WP-5: kServerRevisionCas is gone. The client uses revision CAS only
      // when the server advertises `revision_cas` (false until G4).
      expect(File('lib/core/sync/sync_capabilities.dart').existsSync(), isFalse);
      final gate = File('lib/data/sync/revision_cas.dart').readAsStringSync();
      expect(gate, isNot(contains('const bool')));
      expect(gate, contains('ServerCapabilityState.unsupported'));
    });
  });

  group('H-4 — PUSH: unverified transport is parked', () {
    test('canonical + unknown ⇒ parked', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.unknown,
        ),
        isTrue,
      );
    });

    test('canonical + unsupported ⇒ parked', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.unsupported,
        ),
        isTrue,
      );
    });

    test('canonical + verifiedExact ⇒ allowed (positive proof enables)', () {
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.verifiedExact,
        ),
        isFalse,
      );
    });
  });

  group('H-4 — PULL authority is positive-proof only', () {
    test('UNKNOWN blocks pull', () {
      // The decisive rule: an unverified transport is not an authorised one.
      // Decoder strictness proves PAYLOAD safety, never TRANSPORT authority.
      expect(exactPullAllowed(ExactTransportCapability.unknown), isFalse,
          reason: 'unknown must fail closed — only positive proof may enable a '
              'financial transport');
    });

    test('UNSUPPORTED blocks pull', () {
      expect(exactPullAllowed(ExactTransportCapability.unsupported), isFalse);
    });

    test('verifiedExact allows pull', () {
      expect(exactPullAllowed(ExactTransportCapability.verifiedExact), isTrue);
    });

    test('push and pull are SYMMETRIC in authority', () {
      // Same capability value ⇒ same verdict in both directions.
      for (final cap in const [
        ExactTransportCapability.unknown,
        ExactTransportCapability.unsupported,
      ]) {
        expect(exactPullAllowed(cap), isFalse, reason: '$cap pull');
        expect(
          shouldParkExactMoneyWrite(
              cutoverState: _canonical, pushCapability: cap),
          isTrue,
          reason: '$cap push',
        );
      }
      expect(exactPullAllowed(ExactTransportCapability.verifiedExact), isTrue);
      expect(
        shouldParkExactMoneyWrite(
          cutoverState: _canonical,
          pushCapability: ExactTransportCapability.verifiedExact,
        ),
        isFalse,
      );
    });

    test('decoder strictness remains, as DEFENCE — not as authority', () {
      // Still valuable, still asserted: a non-`::text` payload is refused
      // rather than degraded to a double. But it may never substitute for
      // positive capability authority (requirement 9).
      expect(
        () => moneyFromPulledValue(12.34, 'SAR'),
        throwsA(isA<MoneyTransportException>()),
      );
      expect(
        () => moneyFromPulledValue(1234, 'SAR'),
        throwsA(isA<MoneyTransportException>()),
      );
      expect(moneyFromPulledValue('12.345', 'KWD')!.minorUnits, 12345);
      expect(moneyFromPulledValue(null, 'SAR'), isNull);

      // …and it does NOT unlock the gate.
      expect(exactPullAllowed(ExactTransportCapability.unknown), isFalse,
          reason: 'a strict decoder must never be treated as proof of '
              'transport authority');
    });
  });

  group('H-4 — the Smart Inbox exemption stays justified', () {
    test('smart inbox sync carries no exact-money transport', () {
      // It is the ONE pull deliberately left outside the money gate. That is
      // only correct while it moves no money — if it ever gains a money column
      // this fails, and the exemption must be revisited rather than inherited.
      final source = File(
        'lib/features/capture/services/smart_inbox_sync_service.dart',
      ).readAsStringSync();
      for (final marker in const [
        'moneyFromPulledValue',
        '::text',
        'kMoneyCodec',
        '_minor',
        'Money',
      ]) {
        expect(source.contains(marker), isFalse,
            reason: 'smart inbox now touches money ("$marker") — it can no '
                'longer be exempt from the exact-transport capability gate');
      }
    });
  });

  group('H-4 — startup races are structurally absent, not merely unobserved',
      () {
    final source =
        File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();

    test('exact push/pull are synchronous build constants — nothing to race with',
        () {
      // Exact push/pull are PostgREST/Postgres type semantics, proven against a
      // real local PostgREST (local-Supabase suite S2/S3/S4) and shipped as plain
      // synchronous Providers returning a constant — resolved identically on the
      // very first read, before any startup step runs.
      for (final name in const [
        'exactPushTransportCapabilityProvider',
        'exactPullTransportCapabilityProvider',
      ]) {
        final start = source.indexOf('final $name');
        final body = source.substring(start, source.indexOf('\n});', start));
        expect(body, contains('Provider<ExactTransportCapability>'),
            reason: '$name must stay synchronous');
        for (final async in const ['Future', 'async', 'await', 'StateNotifier']) {
          expect(body.contains(async), isFalse,
              reason: '$name must not gain an async/mutable path without a '
                  'race review: found "$async"');
        }
      }
    });

    test('planning currency is the ONLY runtime-discovered capability, and the '
        'holder itself never probes', () {
      // 0077 deployment state is unknown at build time, so its capability is a
      // runtime probe result held in a Notifier that starts `unknown` and is
      // only moved by PlanningCurrencyCapabilityProbe. The holder has no I/O.
      final start =
          source.indexOf('class PlanningServerCurrencyCapabilityNotifier');
      final end = source.indexOf('final planningServerCurrencyCapabilityProvider');
      final body = source.substring(start, end);
      expect(body, contains('ExactTransportCapability.unknown'));
      for (final io in const ['Future', 'async', 'await', 'supabase']) {
        expect(body.contains(io), isFalse,
            reason: 'the capability holder must not do I/O itself: "$io"');
      }
    });

    test('activation requires a reviewed code change, not a runtime toggle', () {
      // This is the SAFE property, not a gap to be closed with a flag: a
      // financial transport can only be declared proven by shipping code.
      expect(source.contains('FeatureFlagService'), isFalse);
      expect(source.contains('SharedPreferences'), isFalse);
      expect(source.contains('remoteConfig'), isFalse);
    });

    test('revision CAS is a server capability, never a client constant', () {
      // WP-5: kServerRevisionCas is gone (see the group above).
      expect(File('lib/core/sync/sync_capabilities.dart').existsSync(), isFalse);
    });
  });

  group('H-4 — financial capabilities are not ordinary feature flags', () {
    test('capability providers never consult the feature-flag service', () {
      final source =
          File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();
      for (final forbidden in const [
        'FeatureFlagService',
        'featureFlags',
        'getBool',
        'rollout',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'financial transport authority must not be derivable from '
                'a product flag or a percentage rollout: found "$forbidden"');
      }
    });

    test('capability is never inferred from local schema or cutover state', () {
      final source =
          File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();
      // The providers must be plain declarations; inferring "the server can do
      // it" from local state is exactly the unknown→enabled leap this forbids.
      final pullProvider = source.substring(
        source.indexOf('exactPullTransportCapabilityProvider'),
        source.indexOf('planningServerCurrencyCapabilityProvider'),
      );
      expect(pullProvider.contains('schemaVersion'), isFalse);
      expect(pullProvider.contains('PlanningCutoverState'), isFalse);
    });

    test('exact push/pull are verifiedExact constants; planning currency '
        'ships UNPROVEN (runtime probe only)', () {
      final source =
          File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();
      // Scoped to the PROVIDER bodies — `weakerCapability` legitimately returns
      // verifiedExact when combining two already-proven capabilities.
      for (final name in const [
        'exactPushTransportCapabilityProvider',
        'exactPullTransportCapabilityProvider',
      ]) {
        final start = source.indexOf('final $name');
        expect(start, greaterThan(-1), reason: '$name not found');
        final body = source.substring(start, source.indexOf('\n});', start));
        expect(body, contains('return ExactTransportCapability.verifiedExact;'),
            reason: '$name is a build-constant verified capability');
      }
      final planning = source.substring(
        source.indexOf('class PlanningServerCurrencyCapabilityNotifier'),
        source.indexOf('final planningServerCurrencyCapabilityProvider'),
      );
      expect(planning, contains('build() => ExactTransportCapability.unknown'));
      expect(planning.contains('verifiedExact'), isFalse,
          reason: 'planning currency must never be verified except by the probe');
    });
  });
  group('H-4 — no bypass remains in the wiring', () {
    final providers = File('lib/core/di/app_providers.dart').readAsStringSync();

    String providerBody(String name) {
      final start = providers.indexOf('final $name');
      expect(start, greaterThan(-1), reason: '$name not found');
      return providers.substring(start, providers.indexOf('\n});', start));
    }

    test('every money-bearing pull consults the pull capability', () {
      for (final name in const [
        'accountsPullServiceProvider',
        'ledgerSyncServiceProvider',
        'planningPullServiceProvider',
        'planningChildSyncServiceProvider',
      ]) {
        final body = providerBody(name);
        expect(body, contains('exactPullTransportCapabilityProvider'),
            reason: '$name must read the pull capability');
        expect(body, contains('exactPullAllowed'),
            reason: '$name must gate on it, not merely read it');
      }
    });

    test('planning children resolve distinct push and pull authorities', () {
      final body = providerBody('planningChildSyncServiceProvider');
      expect(body, contains('exactPushTransportCapabilityProvider'));
      expect(body, contains('exactPullTransportCapabilityProvider'));
      expect(
        body,
        contains(
          'pullCapability: () => ref.read(exactPullTransportCapabilityProvider)',
        ),
        reason: 'child pull authority must come from the pull provider, never '
            'from the push predicate',
      );
      expect(body, contains('entityType, planningCap(), pullCap'),
          reason:
              'goal-contribution currency gating must use the pull-direction '
              'transport capability');
    });

    test('planning child pull predicate never falls back to push enablement', () {
      final service = File(
        'lib/features/planning_sync/services/planning_child_sync_service.dart',
      ).readAsStringSync();
      expect(
        service,
        contains('static bool _defaultPullEnabled(String _) => false;'),
      );
      expect(service.contains('isPullEnabled ?? isEnabled'), isFalse,
          reason: 'omitting a pull predicate must fail closed, never reuse the '
              'push-direction predicate');
    });

    test('no money-bearing pull is wired to a bare `() => true`', () {
      for (final name in const [
        'accountsPullServiceProvider',
        'ledgerSyncServiceProvider',
      ]) {
        final body = providerBody(name);
        expect(body.contains('isPullEnabled: () => true'), isFalse,
            reason: '$name had no seam to disable an unsupported transport');
        expect(body.contains('isEnabled: _planningAccountsSyncEnabled'), isFalse,
            reason: '$name shared the push predicate and ignored pull capability');
      }
    });


    test('the startup reconcile obeys push transport authority', () {
      final body = providerBody('startupSyncReconcileServiceProvider');
      expect(body, contains('exactPushTransportCapabilityProvider'));

      final service = File(
        'lib/features/planning_sync/services/startup_sync_reconcile_service.dart',
      ).readAsStringSync();
      // Position-aware: merely MENTIONING the predicate proves nothing — the
      // park check must actually run BEFORE the first backfill is constructed.
      final run = service.substring(service.indexOf('Future<ReconcileOutcome> run('));
      final parkAt = run.indexOf('shouldParkExactMoneyWrite');
      final firstBackfillAt = run.indexOf('AccountsBackfillService(');
      expect(parkAt, greaterThan(-1),
          reason: 'the backfills are a push path and must honour the same '
              'predicate as the outbox push services');
      expect(firstBackfillAt, greaterThan(-1));
      expect(parkAt, lessThan(firstBackfillAt),
          reason: 'the transport gate must precede any remote write');
      // …and the guarded branch must return the non-proven outcome.
      final guarded = run.substring(parkAt, firstBackfillAt);
      expect(guarded, contains('return ReconcileOutcome.blockedUnverifiedTransport'),
          reason: 'a parked reconcile must report a non-proven outcome, never '
              'fall through to ran');
    });

    test('the reconcile fails CLOSED when no capability is supplied', () {
      // A caller that forgets the parameter must not get a permissive default.
      final service = File(
        'lib/features/planning_sync/services/startup_sync_reconcile_service.dart',
      ).readAsStringSync();
      expect(service, contains('ExactTransportCapability.unknown'),
          reason: 'the default capability must be unknown (fail closed), '
              'never verifiedExact');
    });

  });

  group('H-4 — the reconcile cannot push over an unproven transport', () {
    test('blocked is neither proven-complete nor silently successful', () {
      const blocked = ReconcileOutcome.blockedUnverifiedTransport;
      expect(blocked.isProvenComplete, isFalse,
          reason: 'Batch 5 uses isProvenComplete to authorise treating local '
              'data as durable — an unauthorised transport must never qualify');
      expect(blocked, isNot(ReconcileOutcome.ran));
    });

    test('blocked is retried once the capability is proven', () {
      expect(ReconcileOutcome.blockedUnverifiedTransport.shouldRetry, isTrue);
    });

    test('every non-proven outcome is excluded from proven-complete', () {
      for (final outcome in const [
        ReconcileOutcome.failed,
        ReconcileOutcome.blockedUnverifiedTransport,
        ReconcileOutcome.skippedGuest,
      ]) {
        expect(outcome.isProvenComplete, isFalse, reason: '$outcome');
      }
      expect(ReconcileOutcome.ran.isProvenComplete, isTrue);
      expect(ReconcileOutcome.skippedNothingPending.isProvenComplete, isTrue);
    });
  });

}
