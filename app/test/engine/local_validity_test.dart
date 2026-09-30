import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/local_validity.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

ParsedTransaction _txn({
  String? amountText = '42.00',
  String currency = 'SAR',
  TransactionType type = TransactionType.payment,
  double confidence = 0.75,
  String? balanceText,
  double? balance,
  String? foreignText,
  double? foreign,
  String? foreignCurrency,
}) =>
    ParsedTransaction(
      amountText: amountText,
      amount: 42.0,
      currency: currency,
      type: type,
      source: TransactionSource.card,
      rawMerchant: 'STARBUCKS',
      balanceAfterText: balanceText,
      balanceAfter: balance,
      foreignAmountText: foreignText,
      foreignAmount: foreign,
      foreignCurrency: foreignCurrency,
      parseConfidence: confidence,
    );

const _raw = 'Purchase SAR 42.00 At STARBUCKS';

LocalValidityResult _check(
  ParseResult parse, {
  String raw = _raw,
  bool proofWithholds = false,
}) =>
    LocalValidity.check(
        parse: parse, rawMessage: raw, proofWithholds: proofWithholds);

void main() {
  test('a plain grounded transaction is valid', () {
    expect(_check(ParseResult.success(_txn())).isValid, isTrue);
  });

  test('not a transaction is invalid', () {
    expect(_check(ParseResult.notTransaction()).reason,
        LocalInvalidReason.notTransaction);
  });

  test('over-precise or missing money text is invalid', () {
    for (final bad in ['1.234', null]) {
      expect(_check(ParseResult.success(_txn(amountText: bad))).reason,
          LocalInvalidReason.nonExactMoney,
          reason: 'amountText=$bad');
    }
    // An unparseable balance or foreign token is equally non-exact.
    expect(
        _check(ParseResult.success(_txn(balanceText: '9.999', balance: 9.999)))
            .reason,
        LocalInvalidReason.nonExactMoney);
    expect(
        _check(ParseResult.success(_txn(
                foreignText: '1.234',
                foreign: 1.234,
                foreignCurrency: 'USD')))
            .reason,
        LocalInvalidReason.nonExactMoney);
  });

  test('empty currency is invalid', () {
    expect(_check(ParseResult.success(_txn(currency: '  '))).reason,
        LocalInvalidReason.missingCurrency);
  });

  test('unknown or defaulted (undetected) type is invalid', () {
    expect(
        _check(ParseResult.success(_txn(type: TransactionType.unknown)))
            .reason,
        LocalInvalidReason.unknownType);
    expect(_check(ParseResult.success(_txn(), typeUndetected: true)).reason,
        LocalInvalidReason.unknownType);
  });

  test('wording that contradicts the type is invalid', () {
    expect(
        _check(ParseResult.success(_txn()), raw: 'Deposit SAR 42.00 salary')
            .reason,
        LocalInvalidReason.directionContradiction);
  });

  test('catalog amount: uncorroborated invalid, corroborated or absent valid',
      () {
    expect(
        _check(ParseResult.success(_txn(), catalogAmountCorroborated: false))
            .reason,
        LocalInvalidReason.uncorroboratedCatalogAmount);
    expect(
        _check(ParseResult.success(_txn(), catalogAmountCorroborated: true))
            .isValid,
        isTrue);
    expect(_check(ParseResult.success(_txn())).isValid, isTrue);
  });

  test('proof gate withholding is invalid', () {
    expect(_check(ParseResult.success(_txn()), proofWithholds: true).reason,
        LocalInvalidReason.proofWithheld);
  });

  test('confidence, at any level, never decides validity', () {
    for (final c in [0.0, 0.1, 0.5, 0.75, 0.79, 0.89, 0.92, 1.0]) {
      expect(_check(ParseResult.success(_txn(confidence: c))).isValid, isTrue,
          reason: 'confidence=$c');
    }
  });

  test('ParserEngine exposes the catalog corroboration fact', () {
    final generic = const ParserEngine()
        .parse('Purchase SAR 42.00 At STARBUCKS 2026-04-08 12:00',
            senderId: 'UNKNOWN-BANK');
    expect(generic.isTransaction, isTrue);
    expect(generic.catalogAmountCorroborated, isNull);
    expect(generic.typeUndetected, isFalse);
  });

  test('amount ambiguity fact (from the engine) invalidates', () {
    expect(_check(ParseResult.success(_txn(), amountAmbiguous: true)).reason,
        LocalInvalidReason.amountAmbiguous);
    final result = const ParserEngine().parse('''
Purchase SAR 45.00 At GROCERY
Amount SAR 50.00
2026-04-08 12:00''', senderId: 'SNB');
    expect(result.amountAmbiguous, isTrue);
    expect(
        LocalValidity.check(
                parse: result, rawMessage: 'x', proofWithholds: false)
            .reason,
        LocalInvalidReason.amountAmbiguous);
  });

  test('date ambiguity fact (from the engine) invalidates', () {
    expect(_check(ParseResult.success(_txn(), dateAmbiguous: true)).reason,
        LocalInvalidReason.dateAmbiguous);
    final result = const ParserEngine().parse(
        'Purchase SAR 42.00 At STARBUCKS 5/6/2026 12:00',
        senderId: 'UNKNOWN-BANK');
    expect(result.dateAmbiguous, isTrue);
  });
}
