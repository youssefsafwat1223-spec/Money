class SentryConfig {
  const SentryConfig._();

  static const dsn = String.fromEnvironment('SENTRY_DSN');

  static bool get isConfigured => dsn.isNotEmpty;
}
