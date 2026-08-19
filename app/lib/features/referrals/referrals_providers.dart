import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show featureFlags;
import 'referral_models.dart';
import 'services/referral_service.dart';

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
  return ref.watch(referralServiceProvider).getSummary();
});
