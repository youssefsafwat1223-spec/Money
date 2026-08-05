// MALI-032 — structured, privacy-safe operational error contract.
//
// Most exceptions in this app carry free-form messages that can embed user data
// (an SMS body, a merchant name, an amount, a decrypted value). The telemetry
// boundary therefore DROPS free-form exception messages by default. Where code
// wants a meaningful, greppable signal to survive into telemetry, it throws (or
// reports) a [TelemetryError] instead: only its stable [code] — drawn from the
// fixed vocabulary in [TelemetryCodes] — and the optional allowlisted
// [module]/[operation]/[retryable] identifiers are ever transmitted.
library;

/// A structured operational error. The [code] is a stable, dot-namespaced
/// identifier from [TelemetryCodes] (e.g. `sync.network_timeout`). Never put
/// user data in any field — these values pass the telemetry allowlist verbatim.
class TelemetryError implements Exception {
  const TelemetryError(
    this.code, {
    this.module,
    this.operation,
    this.retryable,
  });

  /// Stable identifier, e.g. `storage.decrypt_failed`. See [TelemetryCodes].
  final String code;

  /// Coarse subsystem, e.g. `sync`, `storage`, `report`. Allowlisted.
  final String? module;

  /// Coarse operation within the module, e.g. `pull`, `export`. Allowlisted.
  final String? operation;

  /// Whether the caller may safely retry. Allowlisted.
  final bool? retryable;

  @override
  String toString() => 'TelemetryError($code)';
}

/// The fixed vocabulary of operational error codes. Keep these coarse and
/// data-free — one code per distinct failure mode, never per instance.
class TelemetryCodes {
  const TelemetryCodes._();

  // Remote sync / catalog.
  static const String syncNetworkTimeout = 'sync.network_timeout';
  static const String syncUnavailable = 'sync.unavailable';
  static const String syncUnsupportedSchema = 'sync.unsupported_schema';
  static const String syncDecodeFailed = 'sync.decode_failed';

  // Local encrypted storage / database.
  static const String storageDecryptFailed = 'storage.decrypt_failed';
  static const String storageKeyUnavailable = 'storage.key_unavailable';
  static const String databaseMigrationFailed = 'database.migration_failed';
  static const String databaseConstraint = 'database.constraint_violation';

  // Reports / exports / temporary files.
  static const String exportWriteFailed = 'export.write_failed';
  static const String exportShareFailed = 'export.share_failed';
  static const String exportCleanupFailed = 'export.cleanup_failed';

  // Merchant logo / third-party assets.
  static const String logoFetchFailed = 'logo.fetch_failed';

  // Notifications.
  static const String notificationScheduleFailed =
      'notification.schedule_failed';
}
