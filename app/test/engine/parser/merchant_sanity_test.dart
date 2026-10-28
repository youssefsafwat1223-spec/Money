import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/parser/merchant_sanity.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  const ipn = 'IPN transfer sent with amount of EGP 1.00 from 1938 on 28/10 '
      'at 01:43 AM. Ref# 22762b03. For more details call 16607';

  test('IPN/InstaPay text is named InstaPay whatever merchant was captured', () {
    for (final text in [
      ipn,
      'Your account was credited by EGP 2000 on 14-06 23:10 IPN REF# 998877',
      'تم تحويل مبلغ 1.00 جنيه عبر انستاباي',
      'Instapay transfer received EGP 5',
    ]) {
      expect(MerchantSanity.forMessage('01', text), 'InstaPay', reason: text);
      expect(MerchantSanity.forMessage(null, text), 'InstaPay', reason: text);
    }
  });

  test('a time, date or reference is never a merchant; names pass through', () {
    for (final m in ['01', '10', '12', '01:43', '10:37 AM', '28/10', '1938']) {
      expect(MerchantSanity.forMessage(m, 'Debited SAR 5 at $m'), isNull,
          reason: m);
    }
    expect(MerchantSanity.forMessage('CARREFOUR', 'Purchase at CARREFOUR'),
        'CARREFOUR');
    expect(MerchantSanity.forMessage('7-Eleven', 'Purchase at 7-Eleven'),
        '7-Eleven');
    expect(MerchantSanity.isInstaPayText('SNIPNET purchase'), isFalse);
  });

  test('on-device parser names an IPN transfer InstaPay, not its hour', () {
    final tx = const ParserEngine()
        .parse(ipn, senderId: 'IPN', defaultCurrency: 'EGP')
        .transaction!;
    expect(tx.rawMerchant, 'InstaPay');
  });

  test('an AI merchant that is only digits is not grounded', () {
    final v = const AiCandidateValidator().validate(
      response: const AiParseResponse(
        amount: 1,
        amountText: '1.00',
        currency: 'EGP',
        type: 'payment',
        direction: 'debit',
        merchantName: '01',
      ),
      sanitizedText: ipn,
      localParsed: null,
      messageText: ipn,
      normalizedType: TransactionType.payment,
    );
    expect(v.accepted, isTrue);
    expect(v.merchantName, isNull);
  });
}
