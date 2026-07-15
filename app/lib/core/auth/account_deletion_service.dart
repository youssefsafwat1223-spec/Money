import 'package:supabase_flutter/supabase_flutter.dart';

import '../backend/supabase_config.dart';
import '../../domain/errors/repo_exceptions.dart';

/// Current pending-deletion status for the signed-in user, per the approved
/// 30-day account deletion policy (docs/USER_DELETION_DECISION_BRIEF.md).
class AccountDeletionStatus {
  const AccountDeletionStatus({this.scheduledAt});

  final DateTime? scheduledAt;

  bool get isPending => scheduledAt != null;
}

/// Thin client for the account-deletion RPCs. Never used directly by
/// widgets; go through the providers in account_deletion_providers.dart.
class AccountDeletionService {
  AccountDeletionService({SupabaseClient Function()? getClient})
      : _getClient = getClient ?? (() => Supabase.instance.client);

  final SupabaseClient Function() _getClient;

  Future<AccountDeletionStatus> getStatus() async {
    if (!SupabaseConfig.isConfigured) return const AccountDeletionStatus();
    final userId = _getClient().auth.currentUser?.id;
    if (userId == null) return const AccountDeletionStatus();
    try {
      final row = await _getClient()
          .from('profiles')
          .select('delete_scheduled_at')
          .eq('id', userId)
          .maybeSingle();
      final raw = row?['delete_scheduled_at'] as String?;
      return AccountDeletionStatus(
        scheduledAt: raw == null ? null : DateTime.tryParse(raw)?.toUtc(),
      );
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  /// Schedules deletion 30 days out. Idempotent — calling this again while
  /// already scheduled returns the existing date, never pushes it forward.
  /// Returns null in offline/stub mode (nothing to schedule against) rather
  /// than throwing — the caller proceeds with the local-only wipe either way.
  Future<DateTime?> requestDeletion() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final response = await _getClient().rpc('request_account_deletion');
      return DateTime.parse(response as String).toUtc();
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<void> cancelDeletion() async {
    if (!SupabaseConfig.isConfigured) return;
    try {
      await _getClient().rpc('cancel_account_deletion');
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }
}
