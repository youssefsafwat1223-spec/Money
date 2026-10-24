import '../../data/db/app_database.dart';
import 'admission_authority.dart';

/// The typed local write behind the merchant-personalization switch.
///
/// Merchant personalization is a LOCAL-ONLY preference: it is not a consent, so
/// it is NOT authorized by a `ConsentCapability` (which authorizes consent
/// decisions and nothing else). It runs under the general authenticated
/// local-work [AdmissionAuthority] (`AppSession.captureLocalWorkAuthority`, run
/// inside the session's local drain), which has no creation privilege and does
/// not exist during first onboarding.
///
/// Unlike the generic settings save it takes no entity: it changes exactly one
/// column, in one transaction, and never touches a consent state, version or
/// timestamp, the settings outbox, or any backend registration/sync.
abstract class MerchantPreferenceWriter {
  /// Persists [enabled] as the merchant-personalization preference. [authority]
  /// and [database] are what the caller captured before its first await; the
  /// implementation verifies them (and the replica owner) INSIDE its transaction
  /// and throws [StaleAdmissionException] if the lifecycle ended.
  Future<void> saveMerchantPersonalization(
    AdmissionAuthority authority,
    AppDatabase? database,
    bool enabled,
  );
}
