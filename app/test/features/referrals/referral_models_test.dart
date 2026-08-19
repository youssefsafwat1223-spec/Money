import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/referrals/referral_error.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  group('ReferralSummary.fromJson', () {
    test('parses the full server summary shape', () {
      final s = ReferralSummary.fromJson({
        'referral_code': 'QK7F9X2M',
        'progress': 3,
        'required_referrals': 5,
        'reward_days': 7,
        'repeatable': true,
        'cycle_index': 2,
        'cycle_state': 'open',
        'referrals_available': true,
        'attribution_status': 'attributed',
        'entitlement_status': 'active',
        'entitlement_ends_at': '2026-09-01T00:00:00Z',
        'server_now': '2026-08-17T00:00:00Z',
      });
      expect(s.referralCode, 'QK7F9X2M');
      expect(s.progress, 3);
      expect(s.requiredReferrals, 5);
      expect(s.rewardDays, 7);
      expect(s.cycleIndex, 2);
      expect(s.attributionStatus, AttributionStatus.attributed);
    });

    test('tolerates a null rule (no active/pinned rule)', () {
      final s = ReferralSummary.fromJson({
        'referral_code': 'ABCD1234',
        'progress': 0,
        'required_referrals': null,
        'reward_days': null,
        'repeatable': null,
        'cycle_index': 1,
        'cycle_state': 'awaiting_rule',
        'referrals_available': false,
        'attribution_status': 'none',
        'entitlement_status': 'none',
        'entitlement_ends_at': null,
        'server_now': '2026-08-17T00:00:00Z',
      });
      expect(s.requiredReferrals, isNull);
      expect(s.rewardDays, isNull);
      expect(s.attributionStatus, AttributionStatus.none);
    });

    test('entitlementActive uses the SERVER clock, never the device clock', () {
      // ends_at is after server_now => active, regardless of the local time.
      final active = ReferralSummary.fromJson({
        'referral_code': 'X',
        'progress': 0,
        'cycle_index': 1,
        'cycle_state': 'open',
        'referrals_available': true,
        'attribution_status': 'none',
        'entitlement_status': 'active',
        'entitlement_ends_at': '2026-08-20T00:00:00Z',
        'server_now': '2026-08-17T00:00:00Z',
      });
      expect(active.entitlementActive, isTrue);

      // ends_at before server_now => not active even though status says active.
      final expired = ReferralSummary.fromJson({
        'referral_code': 'X',
        'progress': 0,
        'cycle_index': 1,
        'cycle_state': 'open',
        'referrals_available': true,
        'attribution_status': 'none',
        'entitlement_status': 'active',
        'entitlement_ends_at': '2026-08-10T00:00:00Z',
        'server_now': '2026-08-17T00:00:00Z',
      });
      expect(expired.entitlementActive, isFalse);
    });
  });

  group('ApplyCodeOutcome.fromJson', () {
    test('soft failure carries a reason and no qualification', () {
      final o = ApplyCodeOutcome.fromJson({'ok': false, 'reason': 'invalid_code'});
      expect(o.ok, isFalse);
      expect(o.reason, ReferralReason.invalidCode);
      expect(o.qualification, isNull);
    });

    test('success carries the inline qualification attempt', () {
      final o = ApplyCodeOutcome.fromJson({
        'ok': true,
        'attributed': true,
        'qualification': {'qualified': true, 'granted': false, 'progress': 1, 'required': 5},
      });
      expect(o.ok, isTrue);
      expect(o.qualification!.qualified, isTrue);
      expect(o.qualification!.progress, 1);
      expect(o.qualification!.required, 5);
    });
  });

  group('referral error mapping (§9 — no raw token/SQL/id leak)', () {
    late AppL10n l10n;
    setUpAll(() async {
      l10n = await AppL10n.delegate.load(const Locale('en'));
    });

    test('each known reason token maps to distinct controlled copy', () {
      expect(referralReasonMessage(l10n, ReferralReason.invalidCode),
          l10n.referralErrorInvalidCode);
      expect(referralReasonMessage(l10n, ReferralReason.selfReferral),
          l10n.referralErrorSelfReferral);
      expect(referralReasonMessage(l10n, ReferralReason.alreadyReferred),
          l10n.referralErrorAlreadyReferred);
      expect(referralReasonMessage(l10n, ReferralReason.noActiveRule),
          l10n.referralErrorNoActiveRule);
      expect(referralReasonMessage(l10n, ReferralReason.identityUnverified),
          l10n.referralErrorIdentityUnverified);
    });

    test('an unknown/raw token never surfaces verbatim — falls back to generic', () {
      final msg = referralReasonMessage(l10n, 'some_internal_sql_token_42');
      expect(msg, l10n.referralErrorGeneric);
      expect(msg.contains('sql'), isFalse);
      expect(msg.contains('token'), isFalse);
    });

    test('thrown errors map through RepoException without exposing internals', () {
      expect(referralThrownMessage(l10n, const ForbiddenRepoException('42501 privilege')),
          l10n.referralErrorIdentityUnverified);
      expect(referralThrownMessage(l10n, const NetworkRepoException()),
          l10n.referralErrorBody);
      expect(referralThrownMessage(l10n, const ServerRepoException('raw server text')),
          l10n.referralErrorGeneric);
    });
  });
}
