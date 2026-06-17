import 'dart:developer' as developer;

import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  const engine = ParserEngine();

  final cases = [
    (
      '3/9/2026  → March  9 (mdy, 4-digit)',
      'stcbank',
      'إضافة أموال لحسابك\nبـ:300.56 ر.س\nعبر:*X\nفي:3/9/2026 11:17 PM',
      DateTime(2026, 3, 9, 11, 17)
    ),
    (
      '09/03/26  → March  9 (dmy, 2-digit)',
      'stcbank',
      'حوالة داخلية صادرة\nبـ:300.56ر.س\nإلى:NAME\nحساب:5438*\nفي:09/03/26 23:23',
      DateTime(2026, 3, 9, 23, 23)
    ),
    (
      '4/16/2026 → April 16 (mdy, 4-digit)',
      'stcbank',
      'عملية انترنت\nبـ:USD 19.99\nمن:NETFLIX\nبطاقة:*7238\nفي:4/16/2026 09:30',
      DateTime(2026, 4, 16, 9, 30)
    ),
    (
      '16/04/26  → April 16 (dmy, 2-digit)',
      'stcbank',
      'عملية انترنت\nبـ:USD 248.95\nمن:ALIEXP\nبطاقة:*7238\nفي:16/04/26 10:48',
      DateTime(2026, 4, 16, 10, 48)
    ),
  ];

  var ok = true;
  for (final (label, sender, sms, wantDate) in cases) {
    final r = engine.parse(sms, senderId: sender);
    final got = r.transaction?.occurredAt;
    final pass = got == wantDate;
    developer.log('${pass ? "✅" : "❌"} $label  got=$got');
    if (!pass) ok = false;
  }

  // Ambiguous date safety net
  final ambig = engine.parse(
      'Purchase SAR 99.00 at RESTAURANT on 5/6/2026 12:00',
      senderId: 'UNKNOWN-BANK');
  final conf = ambig.transaction?.parseConfidence ?? 0.0;
  final safetyPass = ambig.isTransaction && conf < 0.92;
  developer.log(
    '${safetyPass ? "✅" : "❌"} 5/6/2026 unknown bank → conf=$conf (must be < 0.92 auto-confirm)',
  );
  if (!safetyPass) ok = false;

  developer.log('\n${ok ? "ALL PASS" : "FAILURES ABOVE"}');
}
