import '../../domain/entities/supporting_entities.dart';

/// Every distinct class of data that can leave the device.
///
/// The taxonomy exists so consent is answered ONCE per class at the egress
/// boundary, instead of each service inventing its own check — which is how
/// F-025/C-3 happened: `cloudProcessingEnabled` gated capture upload and two
/// analytics call sites, and nothing else, while the privacy screen promised it
/// disabled synchronisation.
enum EgressClass {
  /// Money and the records that describe it: accounts, transactions, budgets,
  /// goals, subscriptions, plans, cards, bill payments, goal contributions.
  financialSync,

  /// `user_settings` — carries `display_name`, `phone_number`, `date_of_birth`.
  /// Separate from [financialSync] because it is PII rather than money.
  profileAndSettings,

  /// The encrypted backup blob and its metadata row.
  backup,

  /// Captured message content sent for cloud parsing (`parse-sms`), bank
  /// discovery, and merchant enrichment. The most sensitive class: raw bank SMS.
  aiProcessing,

  /// Which banks the user holds — inferred from sender→bank mappings. Not money,
  /// but a direct read on the user's financial life.
  senderBankMappings,

  /// Smart Inbox items.
  smartInbox,

  /// XP, levels, achievements, streaks, engagement events.
  gamification,

  /// Product analytics, metrics, notification delivery logs, the activity ping.
  telemetry,

  /// Crash/error reporting (Sentry). Called out separately from [telemetry]
  /// because OD-05 gives it its own explicit contract.
  diagnostics,

  /// Remote catalog: banks, parsers, flags, announcements, coupons, campaigns.
  /// Contains NO user data and is required for the app to be correct at all
  /// (parser rules, kill switches, force-update). Never consent-gated.
  catalog,

  /// Authentication with the identity provider. Never consent-gated: the user
  /// is deliberately signing in.
  auth,
}

/// The single authority deciding whether a class of data may leave this device.
///
/// ## Why this exists
/// Enforcement used to be per-service opt-in, so every new service shipped
/// ungated by default — and several did. Two independent examples found in
/// review: `RemoteBackupController` defaults its consent callback to
/// `() => true` and the provider never passes one, and the Smart Inbox pull gate
/// is a hardcoded `() => true`. A toggle that services may forget to read is not
/// enforcement.
///
/// ## Semantics
/// * **Fail closed.** `unset` and `declined` both deny. Only an explicit
///   `accepted` permits, matching [UserSettingsEntity.cloudProcessingEnabled].
/// * **Cloud is the master gate (OD-07 restrictive-wins).** AI processing
///   requires cloud consent AND AI consent. Granting AI alone must never open an
///   egress path, because the AI path transmits the same content the cloud path
///   does. The sync payload and the iOS bridge already enforced this; the in-app
///   parse path did not.
/// * **Diagnostics fail closed (OD-05).** Crash reporting can carry device,
///   user and context information, so it follows cloud consent. A future
///   genuinely-anonymous essential channel needs its own documented contract —
///   it is not assumed here.
/// * **Catalog and auth are never gated.** Catalog carries no user data and
///   delivers the kill switches and parser rules the app needs to be correct;
///   gating it would disable safety controls for privacy-conscious users.
///
/// ## What this class deliberately does NOT do
/// It does not cache. Callers must consult it at the moment of egress, because
/// consent can be revoked between a decision and a retry — and a queued or
/// retried request must observe the revocation, not the state at enqueue time.
class ConsentAuthority {
  const ConsentAuthority(this._settings);

  /// Reads settings FRESH on every call. See the no-caching note above.
  final Future<UserSettingsEntity> Function() _settings;

  /// Whether [egressClass] may transmit right now.
  Future<bool> allows(EgressClass egressClass) async {
    switch (egressClass) {
      case EgressClass.catalog:
      case EgressClass.auth:
        return true;
      default:
        return decide(egressClass, await _settings());
    }
  }

  /// Pure decision function — the whole policy in one readable place, so it can
  /// be exhaustively tested without a database.
  static bool decide(EgressClass egressClass, UserSettingsEntity settings) {
    final cloud = settings.cloudProcessingEnabled;
    switch (egressClass) {
      case EgressClass.catalog:
      case EgressClass.auth:
        return true;

      // Cloud consent is the master gate for everything carrying user data.
      case EgressClass.financialSync:
      case EgressClass.profileAndSettings:
      case EgressClass.backup:
      case EgressClass.senderBankMappings:
      case EgressClass.smartInbox:
      case EgressClass.gamification:
      case EgressClass.telemetry:
      case EgressClass.diagnostics:
        return cloud;

      // OD-07: restrictive state wins. AI needs BOTH.
      case EgressClass.aiProcessing:
        return cloud && settings.aiConsentGranted;
    }
  }

  /// Human-readable reason for a denial — for diagnostics and tests, never for
  /// user-facing copy.
  static String denialReason(EgressClass egressClass, UserSettingsEntity s) {
    if (decide(egressClass, s)) return 'allowed';
    if (egressClass == EgressClass.aiProcessing && !s.cloudProcessingEnabled) {
      return 'ai_requires_cloud_consent';
    }
    if (egressClass == EgressClass.aiProcessing) return 'ai_consent_off';
    return 'cloud_consent_off';
  }
}
