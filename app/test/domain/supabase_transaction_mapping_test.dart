import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/supabase_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';

void main() {
  group('SupabaseTransactionRepository direction/type mapping', () {
    test('directionToServer/directionFromServer round-trip for debit/credit',
        () {
      expect(
        SupabaseTransactionRepository.directionFromServer(
          SupabaseTransactionRepository.directionToServer(
              TransactionDirectionEntity.debit),
        ),
        TransactionDirectionEntity.debit,
      );
      expect(
        SupabaseTransactionRepository.directionFromServer(
          SupabaseTransactionRepository.directionToServer(
              TransactionDirectionEntity.credit),
        ),
        TransactionDirectionEntity.credit,
      );
    });

    test('unknown/null direction maps to unknown both ways', () {
      expect(
        SupabaseTransactionRepository.directionToServer(null),
        'unknown',
      );
      expect(
        SupabaseTransactionRepository.directionFromServer('garbage'),
        TransactionDirectionEntity.unknown,
      );
    });

    test('transfer/refund/income round-trip exactly', () {
      for (final type in [
        TransactionTypeEntity.transfer,
        TransactionTypeEntity.refund,
        TransactionTypeEntity.income,
      ]) {
        final server = SupabaseTransactionRepository.typeToServer(type, null);
        expect(SupabaseTransactionRepository.typeFromServer(server), type);
      }
    });

    test(
      'withdrawal is a documented lossy mapping — becomes payment on the way back '
      '(server transaction_type has no separate withdrawal value)',
      () {
        final server = SupabaseTransactionRepository.typeToServer(
          TransactionTypeEntity.withdrawal,
          null,
        );
        expect(server, 'expense');
        expect(
          SupabaseTransactionRepository.typeFromServer(server),
          TransactionTypeEntity.payment,
        );
      },
    );

    test('unknown type falls back to direction: credit→income, debit→expense',
        () {
      expect(
        SupabaseTransactionRepository.typeToServer(
          TransactionTypeEntity.unknown,
          TransactionDirectionEntity.credit,
        ),
        'income',
      );
      expect(
        SupabaseTransactionRepository.typeToServer(
          TransactionTypeEntity.unknown,
          TransactionDirectionEntity.debit,
        ),
        'expense',
      );
      expect(
        SupabaseTransactionRepository.typeToServer(
          TransactionTypeEntity.unknown,
          null,
        ),
        'unknown',
      );
    });

    test(
        'sourceToServer/sourceFromServer cover every enum value without throwing',
        () {
      for (final source in TransactionSourceEntity.values) {
        final server = SupabaseTransactionRepository.sourceToServer(source);
        expect(() => SupabaseTransactionRepository.sourceFromServer(server),
            returnsNormally);
      }
    });

    test('legacy bank/card rows use honest import provenance', () {
      expect(
        SupabaseTransactionRepository.sourceToServer(
          TransactionSourceEntity.bank,
        ),
        'import',
      );
      expect(
        SupabaseTransactionRepository.sourceToServer(
          TransactionSourceEntity.card,
        ),
        'import',
      );
    });

    test('server transaction status preserves pending and ignored', () {
      expect(
        SupabaseTransactionRepository.statusFromServer('pending'),
        TransactionStatus.pending,
      );
      expect(
        SupabaseTransactionRepository.statusFromServer('ignored'),
        TransactionStatus.ignored,
      );
      expect(
        SupabaseTransactionRepository.statusFromServer(null),
        TransactionStatus.confirmed,
      );
    });
  });
}
