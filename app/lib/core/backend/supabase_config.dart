enum SupabaseEnvironment { production, staging, local }

class SupabaseConfig {
  const SupabaseConfig._();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _envLabel =
      String.fromEnvironment('SUPABASE_ENV', defaultValue: 'production');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
  static SupabaseEnvironment get environment => fromLabel(_envLabel);

  // Public for testability — maps a label string to its enum value.
  static SupabaseEnvironment fromLabel(String label) {
    switch (label) {
      case 'staging':
        return SupabaseEnvironment.staging;
      case 'local':
        return SupabaseEnvironment.local;
      default:
        return SupabaseEnvironment.production;
    }
  }
}
