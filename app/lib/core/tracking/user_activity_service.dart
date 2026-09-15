import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../backend/supabase_config.dart';

/// Tracks when the user is active and updates profiles.last_seen_at.
///
/// Rules:
/// - Cold start (app just launched)  → always writes.
/// - Resume from background          → writes only if > 30 min since last write.
/// - Catalog sync                    → never calls this; completely independent.
/// - Not logged in                   → silently skips.
/// - Cloud consent OFF               → silently skips (see below).
///
/// ## Consent
///
/// This writes when a person opened a money app, which is behavioural data
/// about them even though the payload is one timestamp.
/// `EgressClass.profileAndSettings` returns the cloud grant, and this service
/// did not consult it — it was an ungated egress on every cold start, found by
/// the same runtime recorder that caught the gamification pull
/// (`integration_test/cloud_off_egress_test.dart`).
///
/// The gate is injected rather than read here because this is a static service
/// with no access to the database, and it DEFAULTS CLOSED: until
/// [configureConsentGate] runs during bootstrap, nothing is transmitted. An
/// unconfigured build is silent, not chatty.
class UserActivityService {
  UserActivityService._();

  static const _throttle = Duration(minutes: 30);

  /// Answers "may this transmit right now". Null until bootstrap wires it.
  static Future<bool> Function()? _consentGate;

  /// Wired once, from bootstrap, where the database exists.
  static void configureConsentGate(Future<bool> Function()? gate) {
    _consentGate = gate;
  }

  /// Test-only: restores the unconfigured (closed) state.
  @visibleForTesting
  static void resetForTest() {
    _consentGate = null;
    _lastPingedAt = null;
  }

  // Null on cold start → first ping always writes.
  static DateTime? _lastPingedAt;

  /// Call on cold start and on every app resume.
  /// Fire-and-forget — never awaited on the UI path.
  static Future<void> ping() async {
    if (!SupabaseConfig.isConfigured) {
      return;
    }

    try {
      final now = DateTime.now().toUtc();

      // Skip if pinged recently (resume within throttle window).
      if (_lastPingedAt != null && now.difference(_lastPingedAt!) < _throttle) {
        return;
      }

      final client = supabase.Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) return;

      // Consulted at the moment of egress, not at configuration time: consent
      // can be revoked between a decision and the next resume.
      final gate = _consentGate;
      if (gate == null || !await gate()) {
        // Deliberately does NOT stamp `_lastPingedAt`. A denied ping is not a
        // ping — throttling it would mean the first write after consent is
        // granted could be suppressed for half an hour.
        return;
      }

      await client
          .from('profiles')
          .update({'last_seen_at': now.toIso8601String()}).eq('id', user.id);

      _lastPingedAt = now;
    } catch (e, st) {
      // Never crash the app over activity tracking.
      debugPrint('UserActivityService.ping failed: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  /// Call after a successful sign-in to immediately mark the user as active.
  static Future<void> onSignIn() async {
    _lastPingedAt = null; // Force write regardless of throttle.
    await ping();
  }

  /// Resets state on sign-out so the next sign-in writes fresh.
  static void onSignOut() {
    _lastPingedAt = null;
  }
}
