import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Tracks when the user is active and updates profiles.last_seen_at.
///
/// Rules:
/// - Cold start (app just launched)  → always writes.
/// - Resume from background          → writes only if > 30 min since last write.
/// - Catalog sync                    → never calls this; completely independent.
/// - Not logged in                   → silently skips.
class UserActivityService {
  UserActivityService._();

  static const _throttle = Duration(minutes: 30);

  // Null on cold start → first ping always writes.
  static DateTime? _lastPingedAt;

  /// Call on cold start and on every app resume.
  /// Fire-and-forget — never awaited on the UI path.
  static Future<void> ping() async {
    try {
      final now = DateTime.now().toUtc();

      // Skip if pinged recently (resume within throttle window).
      if (_lastPingedAt != null &&
          now.difference(_lastPingedAt!) < _throttle) {
        return;
      }

      final user = supabase.Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      await supabase.Supabase.instance.client
          .from('profiles')
          .update({'last_seen_at': now.toIso8601String()})
          .eq('id', user.id);

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
