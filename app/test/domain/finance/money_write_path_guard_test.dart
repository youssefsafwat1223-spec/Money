import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money_fields.dart';

// These tables are deliberately outside the safe B8-2.5 scope until their
// base-currency ownership is stable. Their writers remain visible to the
// registry completeness test, but are exempt from this converted-domain guard.
const _baseCurrencyPendingTables = {
  'budgets',
  'goals',
  'goal_contributions',
};

const _baseCurrencyPendingWriterFiles = {
  'lib/data/repositories/drift_budget_repository.dart',
  'lib/data/repositories/drift_goal_repository.dart',
};

// Persistence is centralized here for the converted domains. Adding a new
// writer is an architectural decision: update the registry/codec path first,
// then make the allowlist change explicit in review.
const _approvedPersistenceFiles = {
  'lib/data/db/money_codec.dart',
  'lib/data/repositories/drift_account_repository.dart',
  'lib/data/repositories/drift_bill_repository.dart',
  'lib/data/repositories/drift_plan_repository.dart',
  'lib/data/repositories/drift_repository_support.dart',
  'lib/data/repositories/drift_suspected_duplicate_repository.dart',
  'lib/data/repositories/drift_transaction_repository.dart',
  'lib/features/capture/services/ledger_sync_service.dart',
  'lib/features/planning_sync/services/accounts_pull_service.dart',
  'lib/features/planning_sync/services/planning_pull_service.dart',
  'lib/core/data_portability/drift_financial_importer.dart',
};

Directory _libRoot() {
  final direct = Directory('lib');
  if (direct.existsSync()) return direct;
  final nested = Directory('app/lib');
  if (nested.existsSync()) return nested;
  throw StateError('money-write guard could not locate lib/');
}

String _relativePath(File file) {
  final normalized = file.path.replaceAll('\\', '/');
  final marker = normalized.lastIndexOf('/lib/');
  return marker < 0 ? normalized : normalized.substring(marker + 1);
}

List<File> _productionDartFiles() => _libRoot()
    .listSync(recursive: true)
    .whereType<File>()
    .where(
        (file) => file.path.endsWith('.dart') && !file.path.endsWith('.g.dart'))
    .toList(growable: false);

String _camelCase(String snakeCase) {
  final parts = snakeCase.split('_');
  return parts.first +
      parts
          .skip(1)
          .map((part) => part.isEmpty
              ? ''
              : '${part[0].toUpperCase()}${part.substring(1)}')
          .join();
}

Iterable<MoneyField> get _convertedMoneyFields => kMoneyFields
    .where((field) => !_baseCurrencyPendingTables.contains(field.table));

void main() {
  test('display-only money getters never feed REAL write adapters', () {
    // Registry-driven: adding a money column automatically adds its camelCase
    // display-getter spelling to this narrow write-source scan. This catches
    // Variable.withReal(entity.amount) and sql*RealLiteral(entity.amount)
    // regressions while allowing presentation reads and canonical *Money input.
    final getterNames = {
      for (final field in _convertedMoneyFields) _camelCase(field.column),
    };
    final getterAlternation = getterNames.map(RegExp.escape).join('|');
    final displayGetterWrite = RegExp(
      '(?:Variable(?:<[^>]+>)?\\.withReal|'
      '(?:kMoneyCodec\\.)?sql(?:Nullable)?RealLiteral)\\s*\\('
      '[\\s\\S]{0,160}?\\.\\s*(?:$getterAlternation)\\b',
      multiLine: true,
    );
    final violations = <String>[];
    for (final file in _productionDartFiles()) {
      if (_baseCurrencyPendingWriterFiles.contains(_relativePath(file))) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final match in displayGetterWrite.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        violations.add('${_relativePath(file)}:$line ${match.group(0)}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'display doubles must never be canonical write sources:\n'
          '${violations.join('\n')}',
    );
  });

  test('Money.fromLegacyReal stays inside explicit legacy read/ingress seams',
      () {
    // New data must arrive as exact text/Money. The only production exceptions
    // are the v29 codec read adapter, the factory declaration itself, the
    // named legacy capture adapter, and the legacy financial importer.
    final violations = <String>[];
    for (final file in _productionDartFiles()) {
      final path = _relativePath(file);
      final source = file.readAsStringSync();
      for (final match
          in RegExp(r'Money\.fromLegacyReal\s*\(').allMatches(source)) {
        final allowedFile = path == 'lib/data/db/money_codec.dart' ||
            path == 'lib/domain/finance/money.dart' ||
            path == 'lib/core/data_portability/drift_financial_importer.dart' ||
            // MALI-026 (B8-3 §16, class C): the RETIRED, zero-consumer Supabase
            // financial-summary adapter reads a legacy RPC that returns JSON
            // NUMBERS (no ::text), so fromLegacyReal is the correct EXPLICIT
            // legacy remote-double converter here. Not a canonical write path.
            path ==
                'lib/data/repositories/supabase_financial_summary_service.dart';
        final before = source.substring(0, match.start);
        final captureAdapter = path == 'lib/engine/parser/capture_money.dart' &&
            before.lastIndexOf('legacyLossyNumberToMoney') >
                before.lastIndexOf('}');
        if (!allowedFile && !captureAdapter) {
          final line = '\n'.allMatches(before).length + 1;
          violations.add('$path:$line');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Money.fromLegacyReal found on a non-legacy production path:\n'
          '${violations.join('\n')}',
    );
  });

  test('converted money SQL writes stay in approved persistence files', () {
    // This check is table-aware as well as registry-driven. It searches only
    // INSERT column lists and UPDATE assignments for the registered columns;
    // generic words such as `amount` elsewhere in Dart do not create noise.
    final violations = <String>[];
    final fieldsByTable = <String, Set<String>>{};
    for (final field in _convertedMoneyFields) {
      fieldsByTable
          .putIfAbsent(field.table, () => <String>{})
          .add(field.column);
    }

    for (final file in _productionDartFiles()) {
      final path = _relativePath(file);
      if (_approvedPersistenceFiles.contains(path)) continue;
      final source = file.readAsStringSync();

      for (final entry in fieldsByTable.entries) {
        final table = RegExp.escape(entry.key);
        final insertPattern = RegExp(
          r'\bINSERT(?:\s+OR\s+\w+)?\s+INTO\s+' + table + r'\s*\(([^)]*)\)',
          caseSensitive: false,
          multiLine: true,
        );
        for (final match in insertPattern.allMatches(source)) {
          final columns = match.group(1)!;
          final written = entry.value
              .where((column) =>
                  RegExp('\\b${RegExp.escape(column)}\\b', caseSensitive: false)
                      .hasMatch(columns))
              .toList(growable: false);
          if (written.isEmpty) continue;

          // The database bootstrap creates an empty default account with NULL
          // balances. It establishes no monetary value and is not a money
          // persistence path; every non-NULL writer remains guarded.
          final tail = source.substring(match.end);
          final nullDefaultAccountSeed = entry.key == 'accounts' &&
              written.length == 2 &&
              RegExp(
                r"\bVALUES\s*\(\s*\?\s*,\s*\?\s*,\s*\?\s*,\s*'bank'\s*,\s*NULL\s*,\s*NULL\b",
                caseSensitive: false,
              ).hasMatch(
                tail.substring(0, tail.length < 500 ? tail.length : 500),
              );
          if (nullDefaultAccountSeed) continue;

          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          violations
              .add('$path:$line INSERT ${entry.key}.${written.join(',')}');
        }

        final updatePattern = RegExp(
          r'\bUPDATE\s+' + table + r'\s+SET\s+([\s\S]*?)(?:\bWHERE\b|;)',
          caseSensitive: false,
          multiLine: true,
        );
        for (final match in updatePattern.allMatches(source)) {
          final assignments = match.group(1)!;
          final written = entry.value
              .where((column) => RegExp(
                    '\\b${RegExp.escape(column)}\\s*=',
                    caseSensitive: false,
                  ).hasMatch(assignments))
              .toList(growable: false);
          if (written.isEmpty) continue;
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          violations
              .add('$path:$line UPDATE ${entry.key}.${written.join(',')}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'converted-domain money SQL escaped the approved writer set:\n'
          '${violations.join('\n')}',
    );
  });
}
