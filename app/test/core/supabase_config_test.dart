import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/supabase_config.dart';

void main() {
  group('SupabaseConfig.fromLabel', () {
    test('staging label resolves to staging', () {
      expect(
        SupabaseConfig.fromLabel('staging'),
        SupabaseEnvironment.staging,
      );
    });

    test('local label resolves to local', () {
      expect(
        SupabaseConfig.fromLabel('local'),
        SupabaseEnvironment.local,
      );
    });

    test('production label resolves to production', () {
      expect(
        SupabaseConfig.fromLabel('production'),
        SupabaseEnvironment.production,
      );
    });

    test('empty string resolves to production (safe default)', () {
      expect(
        SupabaseConfig.fromLabel(''),
        SupabaseEnvironment.production,
      );
    });

    test('unknown label resolves to production (safe default)', () {
      expect(
        SupabaseConfig.fromLabel('dev'),
        SupabaseEnvironment.production,
      );
    });

    test('label is case-sensitive — STAGING is not staging', () {
      expect(
        SupabaseConfig.fromLabel('STAGING'),
        SupabaseEnvironment.production,
      );
    });
  });
}
