import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/manual_paste_splitter.dart';

void main() {
  test('splits same-bank IPN messages pasted one per line', () {
    const raw = '''
IPN transfer sent with amount of EGP 470.00 from 1938 on 28/06 at 01:50 PM. Ref# 1cff7b2b. For more details call 16607
IPN transfer sent with amount of EGP 500.00 from 1938 on 28/06 at 01:52 PM. Ref# 2bb12740. For more details call 16607
IPN transfer sent with amount of EGP 2220.00 from 1938 on 28/06 at 01:57 PM. Ref# 96c75a6e. For more details call 16607
''';

    final parts = ManualPasteSplitter.split(raw);

    expect(parts, hasLength(3));
    expect(parts[0], contains('EGP 470.00'));
    expect(parts[1], contains('EGP 500.00'));
    expect(parts[2], contains('EGP 2220.00'));
  });

  test('splits transaction messages separated by blank lines', () {
    const raw = '''
Your Debit Card **5398 had a Successful transaction of EGP 200.00 @BDC OROBA,your available bal.EGP1204.74 for lost/stolen card call 16607.

IPN transfer sent with amount of EGP 31.43 from 1938 on 15/03 at 02:18 PM. Ref# 22762b03. For more details call 16607
''';

    final parts = ManualPasteSplitter.split(raw);

    expect(parts, hasLength(2));
  });

  test('keeps one multiline transaction as a single message', () {
    const raw = '''
عملية شراء
بطاقة: مدى ****4521
مبلغ: SAR 45.00
لدى: NETFLIX
في: 2026-04-08 12:45
''';

    final parts = ManualPasteSplitter.split(raw);

    expect(parts, [raw.trim()]);
  });

  test('keeps uncertain prose as one message', () {
    const raw = '''
دي رسالة طويلة فيها كلام كتير
وفيها رقم 200 لكن مش رسالة بنك واضحة
فماينفعش نقطعها
''';

    final parts = ManualPasteSplitter.split(raw);

    expect(parts, [raw.trim()]);
  });
}
