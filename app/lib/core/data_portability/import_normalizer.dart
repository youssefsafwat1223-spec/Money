import 'package:money_companion/core/data_portability/data_portability_models.dart';

class ImportNormalizer {
  static Map<String, List<Map<String, String>>> normalize(
    Map<String, List<Map<String, String>>> rawTables,
    ImportMode mode,
  ) {
    final normalized = <String, List<Map<String, String>>>{};

    final rawAccounts = rawTables['accounts'] ?? [];
    normalized['accounts'] = _normalizeAccounts(rawAccounts, mode);

    final rawCategories = rawTables['custom_categories'] ?? [];
    normalized['custom_categories'] = _normalizeCategories(rawCategories);

    final rawTransactions = rawTables['transactions'] ?? [];
    normalized['transactions'] = _normalizeTransactions(rawTransactions);

    final rawBudgets = rawTables['budgets'] ?? [];
    normalized['budgets'] = _normalizeBudgets(rawBudgets);

    final rawSubscriptions = rawTables['subscriptions'] ?? [];
    normalized['subscriptions'] = _normalizeSubscriptions(rawSubscriptions);

    final rawGoals = rawTables['goals'] ?? [];
    normalized['goals'] = _normalizeGoals(rawGoals);

    final rawPlans = rawTables['plans'] ?? [];
    normalized['plans'] = _normalizePlans(rawPlans);

    normalized['goal_contributions'] = rawTables['goal_contributions'] ?? [];
    normalized['bill_payments'] = rawTables['bill_payments'] ?? [];
    normalized['plan_transaction_links'] =
        rawTables['plan_transaction_links'] ?? [];

    return normalized;
  }

  static List<Map<String, String>> _normalizeAccounts(
      List<Map<String, String>> raw, ImportMode mode) {
    final normalized = <Map<String, String>>[];
    bool defaultFound = false;

    for (final row in raw) {
      final out = Map.of(row);

      out['type'] =
          _mapEnum(out['type'], ['cash', 'bank', 'wallet', 'card'], 'bank');

      final isDefaultStr = out['is_default']?.toLowerCase();
      bool isDefault =
          isDefaultStr == '1' || isDefaultStr == 'true' || isDefaultStr == 't';

      if (mode == ImportMode.merge) {
        isDefault = false;
      } else {
        if (isDefault) {
          if (defaultFound) {
            isDefault = false;
          } else {
            defaultFound = true;
          }
        }
      }
      out['is_default'] = isDefault ? 'true' : 'false';

      normalized.add(out);
    }
    return normalized;
  }

  static List<Map<String, String>> _normalizeCategories(
      List<Map<String, String>> raw) {
    return raw;
  }

  static List<Map<String, String>> _normalizeTransactions(
      List<Map<String, String>> raw) {
    final normalized = <Map<String, String>>[];
    for (final row in raw) {
      final out = Map.of(row);

      out['direction'] =
          _mapEnum(out['direction'], ['debit', 'credit', 'unknown'], 'unknown');
      out['transaction_type'] = _mapEnum(
          out['type'] ?? out['transaction_type'],
          ['income', 'expense', 'transfer', 'refund', 'adjustment', 'unknown'],
          _deriveType(out['type']));
      out['status'] = _mapEnum(
          out['status'], ['confirmed', 'pending', 'ignored'], 'confirmed');
      out['source'] = _mapEnum(
          out['source'],
          [
            'ios_shortcut',
            'android_sms',
            'manual',
            'import',
            'share_extension',
            'gemini',
            'user_manual',
            'remote',
            'recurring'
          ],
          'import');

      final compSrc = out['comparison_timestamp_source'] ?? '';
      out['comparison_timestamp_source'] =
          compSrc == 'sms_body' ? 'sms_body' : 'received_at';

      if (out['foreign_amount'] != null && out['foreign_amount']!.isNotEmpty) {
        final fAmount = double.tryParse(out['foreign_amount']!);
        if (fAmount == null || fAmount <= 0) {
          out.remove('foreign_amount');
          out.remove('foreign_currency');
        }
      }

      normalized.add(out);
    }
    return normalized;
  }

  static String _deriveType(String? legacyType) {
    switch (legacyType) {
      case 'payment':
      case 'withdrawal':
        return 'expense';
      case 'deposit':
        return 'income';
      case 'transfer':
        return 'transfer';
      default:
        return 'unknown';
    }
  }

  static List<Map<String, String>> _normalizeBudgets(
      List<Map<String, String>> raw) {
    final normalized = <Map<String, String>>[];
    for (final row in raw) {
      final out = Map.of(row);
      out['period'] = _mapEnum(out['period'] ?? out['type'],
          ['daily', 'weekly', 'monthly', 'yearly'], 'monthly');
      normalized.add(out);
    }
    return normalized;
  }

  static List<Map<String, String>> _normalizeSubscriptions(
      List<Map<String, String>> raw) {
    final normalized = <Map<String, String>>[];
    for (final row in raw) {
      final out = Map.of(row);
      out['type'] = _mapEnum(
          out['type'], ['subscription', 'installment'], 'subscription');
      out['frequency'] = _mapEnum(out['frequency'],
          ['weekly', 'monthly', 'yearly', 'custom'], 'monthly');
      out['status'] = _mapEnum(
          out['status'], ['active', 'paused', 'cancelled', 'closed'], 'active');
      normalized.add(out);
    }
    return normalized;
  }

  static List<Map<String, String>> _normalizeGoals(
      List<Map<String, String>> raw) {
    final normalized = <Map<String, String>>[];
    for (final row in raw) {
      final out = Map.of(row);
      out['status'] = _mapEnum(out['status'], ['active', 'closed'], 'active');
      normalized.add(out);
    }
    return normalized;
  }

  static List<Map<String, String>> _normalizePlans(
      List<Map<String, String>> raw) {
    final normalized = <Map<String, String>>[];
    for (final row in raw) {
      final out = Map.of(row);
      out['status'] = _mapEnum(out['status'], ['active', 'closed'], 'active');
      normalized.add(out);
    }
    return normalized;
  }

  static String _mapEnum(String? value, List<String> allowed, String fallback) {
    if (value == null || value.isEmpty) return fallback;
    final normalized = value.toLowerCase().trim();
    if (allowed.contains(normalized)) return normalized;
    return fallback;
  }
}
