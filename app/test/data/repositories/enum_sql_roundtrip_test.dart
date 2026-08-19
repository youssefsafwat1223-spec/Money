// Every enum written to SQLite must be readable back. The write side is
// `value.name` for the WHOLE enum, so a `fromSql` switch that lists only some
// values is a live landmine: saving the unlisted value succeeds, and every
// later read throws — which is exactly how a `yearly` budget bricked the
// dashboard (`Unknown budget period.: "yearly"`).
//
// These round-trips iterate `.values`, so adding an enum value without
// teaching the reader about it fails HERE instead of in the user's app.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/drift_repository_support.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';

void main() {
  test('every BudgetPeriod survives toSql → fromSql', () {
    for (final period in BudgetPeriod.values) {
      expect(
        budgetPeriodFromSql(budgetPeriodToSql(period)),
        period,
        reason: 'BudgetPeriod.${period.name} is written but cannot be read '
            'back — add it to budgetPeriodFromSql',
      );
    }
  });

  test('every TransactionStatus survives toSql → fromSql', () {
    for (final status in TransactionStatus.values) {
      expect(transactionStatusFromSql(status.name), status,
          reason: 'TransactionStatus.${status.name} cannot be read back');
    }
  });

  test('every TransactionTypeEntity survives toSql → fromSql', () {
    for (final type in TransactionTypeEntity.values) {
      expect(transactionTypeFromSql(type.name), type,
          reason: 'TransactionTypeEntity.${type.name} cannot be read back');
    }
  });

  test('every TransactionSourceEntity survives toSql → fromSql', () {
    for (final source in TransactionSourceEntity.values) {
      expect(transactionSourceFromSql(source.name), source,
          reason: 'TransactionSourceEntity.${source.name} cannot be read back');
    }
  });

  test('every TransactionDirectionEntity survives toSql → fromSql', () {
    for (final direction in TransactionDirectionEntity.values) {
      expect(
        transactionDirectionFromSql(transactionDirectionToSql(direction)),
        direction,
        reason: 'TransactionDirectionEntity.${direction.name} cannot be read '
            'back',
      );
    }
    expect(transactionDirectionFromSql(null), isNull);
  });
}
