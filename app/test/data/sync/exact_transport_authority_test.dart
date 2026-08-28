import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/finance/money_transport.dart';

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

    test('capabilities are synchronous constants — nothing to race with', () {
      // Requirement 7 lists races: not-yet-initialized, fetch failure, stale
      // cache, refresh-during-resume, reconcile-before-resolution. NONE can
      // occur, because there is no discovery mechanism: the providers are
      // plain synchronous Providers returning a constant. They are resolved
      // identically on the very first read, before any startup step runs.
      for (final name in const [
        'exactPushTransportCapabilityProvider',
        'exactPullTransportCapabilityProvider',
        'planningServerCurrencyCapabilityProvider',
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

    test('activation requires a reviewed code change, not a runtime toggle', () {
      // This is the SAFE property, not a gap to be closed with a flag: a
      // financial transport can only be declared proven by shipping code.
      expect(source.contains('FeatureFlagService'), isFalse);
      expect(source.contains('SharedPreferences'), isFalse);
      expect(source.contains('remoteConfig'), isFalse);
    });

    test('server-revision CAS stays off until positively activated', () {
      final caps =
          File('lib/core/sync/sync_capabilities.dart').readAsStringSync();
      expect(caps, contains('const bool kServerRevisionCas = false'),
          reason: 'CAS must remain false unless positively activated');
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

    test('all three capabilities ship UNPROVEN (no accidental activation)', () {
      final source =
          File('lib/data/sync/exact_transport_capability.dart').readAsStringSync();
      // Guards requirement 10: this batch is authority semantics only.
      // Scoped to the PROVIDER bodies — `weakerCapability` legitimately returns
      // verifiedExact when combining two already-proven capabilities.
      for (final name in const [
        'exactPushTransportCapabilityProvider',
        'exactPullTransportCapabilityProvider',
        'planningServerCurrencyCapabilityProvider',
      ]) {
        final start = source.indexOf('final $name');
        expect(start, greaterThan(-1), reason: '$name not found');
        final body = source.substring(start, source.indexOf('\n});', start));
        expect(body, contains('return ExactTransportCapability.unknown;'),
            reason: '$name must still be unknown');
        expect(body.contains('verifiedExact'), isFalse,
            reason: '$name must not be activated until the transport is '
                'externally proven');
      }
    });
  });
}
