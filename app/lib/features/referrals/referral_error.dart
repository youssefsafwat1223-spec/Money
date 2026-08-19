import '../../domain/errors/repo_exceptions.dart';
import '../../l10n/app_localizations.dart';
import 'referral_models.dart';

/// Maps a server SOFT-failure reason token (from a successful RPC returning
/// {ok:false, reason:...} / {qualified:false, reason:...}) to controlled,
/// localized copy. An unknown token falls back to a generic message — a raw
/// token, SQL, RPC name or id is NEVER shown (§9). The 0083 tokens are already
/// kept redactor-safe server-side, but we never render them verbatim regardless.
String referralReasonMessage(AppL10n l10n, String? reason) {
  switch (reason) {
    case ReferralReason.invalidCode:
      return l10n.referralErrorInvalidCode;
    case ReferralReason.selfReferral:
      return l10n.referralErrorSelfReferral;
    case ReferralReason.alreadyReferred:
      return l10n.referralErrorAlreadyReferred;
    case ReferralReason.noActiveRule:
    case ReferralReason.awaitingActiveRule:
      return l10n.referralErrorNoActiveRule;
    case ReferralReason.identityUnverified:
      return l10n.referralErrorIdentityUnverified;
    default:
      // no_attribution, cycle_completed, unknown -> generic, no leak.
      return l10n.referralErrorGeneric;
  }
}

/// Maps a THROWN error (e.g. `unauthenticated` surfaces as a PostgrestException)
/// to controlled copy. Reuses the app-wide RepoException classification but only
/// through the clean, non-interpolating branches so no server text is exposed.
String referralThrownMessage(AppL10n l10n, Object error) {
  final repo = error is RepoException ? error : mapSupabaseError(error);
  switch (repo) {
    case AuthRepoException():
    case ForbiddenRepoException():
      return l10n.referralErrorIdentityUnverified;
    case NetworkRepoException():
      return l10n.referralErrorBody; // "try again in a moment"
    default:
      return l10n.referralErrorGeneric;
  }
}
