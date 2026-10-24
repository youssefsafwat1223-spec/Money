import 'package:supabase_flutter/supabase_flutter.dart';

import '../backend/supabase_config.dart';
import '../privacy/cloud_egress_gate.dart';
import '../../domain/errors/repo_exceptions.dart';
import 'immediate_account_deletion.dart';

/// Current pending-deletion status for the signed-in user, per the approved
/// 30-day account deletion policy (docs/USER_DELETION_DECISION_BRIEF.md).
class AccountDeletionStatus {
  const AccountDeletionStatus({this.scheduledAt});

  final DateTime? scheduledAt;

  bool get isPending => scheduledAt != null;
}

/// The legacy scheduled route is unavailable; this is never deletion success.
class LegacyDeletionUnavailable implements Exception {
  const LegacyDeletionUnavailable();
  String get code => 'legacy_route_unavailable';
  @override
  String toString() => 'LegacyDeletionUnavailable:$code';
}

/// Thin client for the account-deletion RPCs. Never used directly by
/// widgets; go through the providers in account_deletion_providers.dart.
class AccountDeletionService {
  AccountDeletionService({
    SupabaseClient Function()? getClient,
    ImmediateAccountDeletionClient? immediateClient,
    ImmediateAccountDeletionRecovery? immediateRecovery,
  })  : _getClient = getClient ?? (() => Supabase.instance.client),
        _immediateRecovery = immediateRecovery;

  final SupabaseClient Function() _getClient;
  // Raw HTTP alone deliberately does not configure the safe immediate path.
  final ImmediateAccountDeletionRecovery? _immediateRecovery;

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

  /// LEGACY (30-day schedule, migration 0042): still called by PrivacyScreen.
  /// A structured QD003 refusal reports unavailable without local success.
  /// Schedules deletion 30 days out. Idempotent — calling this again while
  /// already scheduled returns the existing date, never pushes it forward.
  /// Returns null in offline/stub mode (nothing to schedule against) rather
  /// than throwing — the caller proceeds with the local-only wipe either way.
  Future<DateTime?> requestDeletion() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      // ESCALATED (Astra H2.1): an explicit account-control operation, scoped to
      // this RPC (+ the strictly necessary refresh_token exchange) only.
      final response = await CloudEgressGate.instance.runAccountControl(
          AccountControlOp.deleteAccount,
          () => _getClient().rpc('request_account_deletion'));
      return DateTime.parse(response as String).toUtc();
    } catch (error) {
      if (error is PostgrestException && error.code == 'QD003') {
        throw const LegacyDeletionUnavailable();
      }
      throw mapSupabaseError(error);
    }
  }

  Future<void> cancelDeletion() async {
    if (!SupabaseConfig.isConfigured) return;
    try {
      await CloudEgressGate.instance.runAccountControl(
          AccountControlOp.cancelDelete,
          () => _getClient().rpc('cancel_account_deletion'));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }
}

/// DRAFT: immediate, permanent deletion (owner-approved; no 30-day grace).
///
/// Declared as an extension, not as class members, so existing test doubles
/// that `implements AccountDeletionService` keep compiling unchanged. The
/// result is [ImmediateDeletionCompleted] only after the server confirms
/// completion; until then the UI must show in-progress or the failure. Reuse
/// the returned `receiptSecret` for every retry or status poll. With no
/// configured durable recovery facade the call fails closed (never a silent success).
extension ImmediateAccountDeletion on AccountDeletionService {
  Future<ImmediateDeletionResult> requestImmediateDeletion({
    required String challengeId,
    required String challengeResponse,
    String? receiptSecret,
  }) {
    final secret = receiptSecret ?? '';
    final client = _immediateRecovery;
    if (client == null) {
      return Future.value(ImmediateDeletionFailed(secret,
          retryable: false, code: 'not_configured'));
    }
    return client.request(
      challengeId: challengeId,
      challengeResponse: challengeResponse,
      receiptSecret: receiptSecret,
    );
  }

  /// Read-only receipt poll for a previously issued [receiptSecret].
  Future<ImmediateDeletionResult> immediateDeletionStatus(
      String receiptSecret) {
    final client = _immediateRecovery;
    if (client == null) {
      return Future.value(ImmediateDeletionFailed(receiptSecret,
          retryable: false, code: 'not_configured'));
    }
    return client.status(receiptSecret: receiptSecret);
  }

  Future<ImmediateDeletionRecoveryHandle?> restoreImmediateDeletion({required String owner}) async =>
      _immediateRecovery?.restore(owner: owner);

  Future<ImmediateDeletionResult> recoverImmediateDeletion(ImmediateDeletionRecoveryHandle handle) =>
      _immediateRecovery?.recover(handle) ?? Future.value(const ImmediateDeletionFailed('',
          retryable: false, code: 'not_configured'));

}
