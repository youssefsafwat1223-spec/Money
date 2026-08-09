import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/transaction_server_mappers.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';

// MALI-034: the transaction enum -> Supabase-wire mappers extracted from the
// retired SupabaseTransactionRepository into an authority-neutral transport file.
// (The reverse *FromServer mappers were internal to the deleted repo; the pull
// services own their own row parsing.)

void main() {
  test('directionToServer: debit / credit / null->unknown', () {
    expect(transactionDirectionToServer(TransactionDirectionEntity.debit),
        'debit');
    expect(transactionDirectionToServer(TransactionDirectionEntity.credit),
        'credit');
    expect(transactionDirectionToServer(null), 'unknown');
  });

  test('typeToServer: transfer/refund/income map exactly', () {
    expect(
        transactionTypeToServer(TransactionTypeEntity.transfer, null),
        'transfer');
    expect(transactionTypeToServer(TransactionTypeEntity.refund, null), 'refund');
    expect(transactionTypeToServer(TransactionTypeEntity.income, null), 'income');
  });

  test('typeToServer: payment/withdrawal collapse to expense (documented lossy)',
      () {
    expect(
        transactionTypeToServer(TransactionTypeEntity.payment, null), 'expense');
    expect(transactionTypeToServer(TransactionTypeEntity.withdrawal, null),
        'expense');
  });

  test('typeToServer: unknown falls back to direction', () {
    expect(
        transactionTypeToServer(
            TransactionTypeEntity.unknown, TransactionDirectionEntity.credit),
        'income');
    expect(
        transactionTypeToServer(
            TransactionTypeEntity.unknown, TransactionDirectionEntity.debit),
        'expense');
    expect(
        transactionTypeToServer(TransactionTypeEntity.unknown, null), 'unknown');
  });

  test('sourceToServer: covers every enum without throwing; bank/card=import',
      () {
    for (final source in TransactionSourceEntity.values) {
      expect(() => transactionSourceToServer(source), returnsNormally);
    }
    expect(transactionSourceToServer(TransactionSourceEntity.bank), 'import');
    expect(transactionSourceToServer(TransactionSourceEntity.card), 'import');
  });
}
