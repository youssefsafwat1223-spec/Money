import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/parser/local_validity.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

import '../engine/fixtures/ambiguous_amount_fixtures.dart';
import '../engine/fixtures/bank_sms_golden_fixtures.dart';
import '../engine/fixtures/ignore_fixtures.dart';
import 'local_v2_support.dart';

Future<String> _status(BankSmsGoldenFixture f, {required bool on}) async {
  final repo = StoringTransactionRepo();
  final result = await AddTransactionUseCase(
    transactionRepository: repo,
    merchantCategoryRepository: NewMerchantRepo(),
    parserIsolate: const FakeParserIsolate(),
    dedupStore: MemoryDedupStore(),
    isLocalAutoConfirmV2: () => on,
  )(rawMessage: f.rawSms, senderId: f.sender);
  if (result.outcome != AddTransactionOutcome.added) return 'none';
  return result.transaction!.status == TransactionStatus.confirmed
      ? 'confirmed'
      : 'pending';
}

void main() {
  setUp(() => AiSenderFailureTracker.instance.resetForTest());

  test('golden corpus under local_auto_confirm_v2: flip report', () async {
    final fixtures = [
      ...realWorldBankSmsFixtures,
      ...parserGateFixtures,
      ...ambiguousAmountFixtures,
      ...ambiguousDateFixtures,
    ];
    final flips = <String, int>{};
    final flipped = <String>[];
    final invalid = <String>[];
    var onPending = 0;
    for (final f in fixtures) {
      final off = await _status(f, on: false);
      final on = await _status(f, on: true);
      flips['$off->$on'] = (flips['$off->$on'] ?? 0) + 1;
      if (on == 'pending') onPending++;
      if (off == 'pending' && on == 'confirmed') {
        final p = const ParserEngine().parse(f.rawSms, senderId: f.sender);
        flipped.add('${f.id}: conf=${p.confidence.toStringAsFixed(2)} '
            'amountAmbiguous=${p.amountAmbiguous} '
            'dateAmbiguous=${p.dateAmbiguous} type=${p.transaction!.type.name}');
      }
      if (off == 'pending' && on == 'none') {
        final parse = const ParserEngine().parse(f.rawSms, senderId: f.sender);
        final v = LocalValidity.check(
            parse: parse, rawMessage: f.rawSms, proofWithholds: false);
        invalid.add('${f.id}: ${v.reason?.name}');
      }
    }
    // ignore: avoid_print
    print('GOLDEN total=${fixtures.length} flips=$flips');
    // ignore: avoid_print
    print('GOLDEN pending->none (invalid):\n${invalid.join('\n')}');
    // ignore: avoid_print
    print('GOLDEN pending->confirmed:\n${flipped.join('\n')}');
    expect(onPending, 0, reason: 'V2 never yields a pending capture');

    // The ignore corpus must remain non-transactions under V2.
    for (final f in ignoreFixtures) {
      expect(await _status(f, on: true), 'none', reason: f.id);
    }
  });
}
