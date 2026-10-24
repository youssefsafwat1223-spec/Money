import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show featureFlags;
import 'referral_error.dart' show isReferralFeatureRetired;
import 'referral_models.dart';
import 'services/referral_service.dart';

/// D6: referrals are retired for Beta 1. Hides every referral entry point.
const bool kReferralsRetired = true;

/// The referral RPC client. Overridden with a fake in tests.
final referralServiceProvider = Provider<ReferralService>(
  (ref) => SupabaseReferralService(),
);

/// Client discovery gate. The server enforces attribution/qualification
/// independently (an active rule), so this governs UI visibility only
/// (docs REFERRAL_REWARDS_SYSTEM.md §19). Fails closed via the flag default.
///
/// NOTE: FeatureFlagService.getBool is a plain in-memory read populated at
/// catalog sync / startup; it is not reactive within a session. A mid-session
/// flip only takes effect after a sync re-runs init() and this provider is
/// invalidated — the same non-instant behaviour every flag has (§20).
final referralsEnabledProvider = Provider<bool>((ref) {
  // D6 (Beta 1): the old referral protocol is permanently retired server-side
  // (QD040). The entry points stay hidden whatever a remote flag says; a new,
  // reviewed protocol must deliberately remove this.
  if (kReferralsRetired) return false;
  // Fail closed if the flag service has not initialised yet (pre-sync / tests):
  // the safe default is "referrals hidden", never a crash.
  try {
    return featureFlags.getBool('enable_referrals');
  } on StateError {
    return false;
  }
});

/// Server-authoritative referral summary. Returns null when the feature is
/// gated off (the screen then shows nothing referral-related).
final referralSummaryProvider = FutureProvider<ReferralSummary?>((ref) async {
  if (!ref.watch(referralsEnabledProvider)) return null;
  try {
    return await ref.watch(referralServiceProvider).getSummary();
  } catch (error) {
    // D6: a retired feature is "not available", never an error state.
    if (isReferralFeatureRetired(error)) return null;
    rethrow;
  }
});
