import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../referral_models.dart';

/// Thin client for the authenticated referral RPCs (0083). Never used directly
/// by widgets — go through the providers in referrals_providers.dart. This is
/// the sanctioned exception to "UI reads only from Drift": the referral domain
/// deliberately has NO Drift table (docs REFERRAL_REWARDS_SYSTEM.md §26), so it
/// is read via RPC and held in-session, exactly like AccountDeletionService.
abstract class ReferralService {
  /// get_referral_summary — self-only code, progress, cycle, entitlement.
  Future<ReferralSummary?> getSummary();

  /// apply_referral_code — the single guarded attribution path (manual code).
  Future<ApplyCodeOutcome> applyCode(String code);

  /// request_referral_qualification — "please evaluate me", self-only, no args.
  Future<QualificationOutcome> requestQualification();

  /// get_entitlement_decision — ad-free report-export status/expiry (display).
  Future<EntitlementDecision?> getEntitlementDecision();
}

class SupabaseReferralService implements ReferralService {
  SupabaseReferralService({SupabaseClient Function()? getClient})
      : _getClient = getClient ?? (() => Supabase.instance.client);

  final SupabaseClient Function() _getClient;

  static const _entitlementType = 'report_export_ad_free';

  Map<String, dynamic> _asMap(Object? response) =>
      Map<String, dynamic>.from(response as Map);

  @override
  Future<ReferralSummary?> getSummary() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final response = await _getClient().rpc('get_referral_summary');
      return ReferralSummary.fromJson(_asMap(response));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<ApplyCodeOutcome> applyCode(String code) async {
    if (!SupabaseConfig.isConfigured) {
      // Offline/unconfigured: treat as "not available" rather than throwing;
      // the caller shows the controlled no_active_rule copy.
      return const ApplyCodeOutcome(ok: false, reason: ReferralReason.noActiveRule);
    }
    try {
      final response =
          await _getClient().rpc('apply_referral_code', params: {'p_code': code});
      return ApplyCodeOutcome.fromJson(_asMap(response));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<QualificationOutcome> requestQualification() async {
    try {
      final response = await _getClient().rpc('request_referral_qualification');
      return QualificationOutcome.fromJson(_asMap(response));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final response = await _getClient().rpc(
        'get_entitlement_decision',
        params: {'p_entitlement_type': _entitlementType},
      );
      return EntitlementDecision.fromJson(_asMap(response));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }
}
