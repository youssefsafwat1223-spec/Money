import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/shared_preview_parser.dart';

/// اختبارات قواعد المعاينة المشتركة (Swift App Intent + Dart mirror).
///
/// الأمثلة تعيش داخل parser_rules.json نفسه حتى تكون عقداً واحداً
/// للمنصتين: أي تعديل في القواعد يجب أن يُبقي الأمثلة ناجحة هنا،
/// وSwift ينفّذ نفس الخوارزمية على نفس الملف.
void main() {
  final jsonString =
      File('assets/catalog/parser_rules.json').readAsStringSync();
  final rules = jsonDecode(jsonString) as Map<String, dynamic>;
  final parser = SharedPreviewParser.fromJsonString(jsonString);
  final examples = (rules['examples'] as List).cast<Map<String, dynamic>>();

  test('rules file has the expected schema and version', () {
    expect(rules['version'], 1);
    for (final key in [
      'normalization',
      'currencyPattern',
      'ignoreKeywords',
      'debitKeywords',
      'creditKeywords',
      'amountPatterns',
      'merchantPatterns',
      'merchantStopPattern',
      'last4Patterns',
      'examples',
    ]) {
      expect(rules, contains(key), reason: 'missing "$key"');
    }
    expect(examples, isNotEmpty);
  });

  test('all regexes compile in Dart (NSRegularExpression-compatible subset)',
      () {
    final patterns = <String>[
      rules['currencyPattern'] as String,
      rules['merchantStopPattern'] as String,
      ...(rules['amountPatterns'] as List).cast<String>(),
      ...(rules['merchantPatterns'] as List).cast<String>(),
      ...(rules['last4Patterns'] as List).cast<String>(),
      for (final item in ((rules['normalization']
              as Map<String, dynamic>)['currencyReplacements'] as List)
          .cast<Map<String, dynamic>>())
        item['pattern'] as String,
    ];
    for (final pattern in patterns) {
      expect(() => RegExp(pattern, caseSensitive: false), returnsNormally,
          reason: 'pattern does not compile: $pattern');
      // named groups و \b ممنوعان (سلوكهما يختلف بين Dart و ICU مع العربية).
      expect(pattern, isNot(contains('(?<')),
          reason: 'named group in: $pattern');
      expect(pattern, isNot(contains(r'\b')),
          reason: r'\b differs between Dart and ICU for Arabic: ' + pattern);
    }
  });

  group('embedded examples parse as expected (contract for Swift too)', () {
    for (final example in examples) {
      final name = example['name'] as String;
      final expected = example['expect'] as Map<String, dynamic>;

      test(name, () {
        final result = parser.parse(example['text'] as String);

        expect(result.outcome.name, expected['outcome'], reason: 'outcome');
        if (expected.containsKey('amount')) {
          expect(result.amount, closeTo(expected['amount'] as num, 0.001));
        }
        if (expected.containsKey('currency')) {
          expect(result.currency, expected['currency']);
        }
        if (expected.containsKey('merchant')) {
          expect(result.merchant, expected['merchant']);
        }
        if (expected.containsKey('last4')) {
          expect(result.last4, expected['last4']);
        }
        // العقد: نوع + مبلغ + عملة = إشعار مفصّل، غير ذلك إشعار عام.
        final shouldBeHigh = (expected['outcome'] == 'debit' ||
                expected['outcome'] == 'credit') &&
            expected.containsKey('amount') &&
            expected.containsKey('currency');
        expect(result.isHighConfidence, shouldBeHigh);
      });
    }
  });

  group('preview never conflicts with ParserEngine on the same SMS', () {
    const engine = ParserEngine();

    for (final example in examples) {
      final expected = example['expect'] as Map<String, dynamic>;
      final outcome = expected['outcome'] as String;

      test(example['name'] as String, () {
        final engineResult = engine.parse(
          example['text'] as String,
          senderId: example['sender'] as String?,
        );
        final transaction = engineResult.transaction;

        if (outcome == 'ignored') {
          // ما نتجاهله في المعاينة يتجاهله المحرك أيضاً — لا إشعار لعملية
          // لن تُسجَّل أصلاً.
          expect(transaction, isNull,
              reason: 'engine parsed a transaction the preview ignored');
          return;
        }
        if (transaction == null) {
          // المحرك أكثر تحفظاً — لا تعارض طالما لم يخرج بعملية مختلفة.
          return;
        }
        if (expected.containsKey('amount')) {
          expect(transaction.amount,
              closeTo(expected['amount'] as num, 0.001),
              reason: 'amount mismatch between preview and engine');
        }
        if (expected.containsKey('currency')) {
          expect(transaction.currency, expected['currency'],
              reason: 'currency mismatch between preview and engine');
        }
        // اتجاه العملية: خصم ↔ مصروف، إيداع ↔ دخل/استرداد.
        // التحويلات تُترك للمحرك (اتجاهها يتحدد لاحقاً في الـ usecase).
        if (transaction.type != TransactionType.transfer &&
            transaction.type != TransactionType.unknown) {
          if (outcome == 'debit') {
            expect(transaction.type.isExpense, isTrue,
                reason: 'preview said debit but engine type is '
                    '${transaction.type}');
          } else if (outcome == 'credit') {
            expect(
                transaction.type == TransactionType.income ||
                    transaction.type == TransactionType.refund,
                isTrue,
                reason: 'preview said credit but engine type is '
                    '${transaction.type}');
          }
        }
      });
    }
  });
}
