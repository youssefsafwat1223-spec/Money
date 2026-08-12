import '../entities/card_summary.dart';
import '../finance/money.dart';

import '../../engine/parser/card_network.dart';

/// صف تجميعي خام لكل (آخر 4 أرقام، حساب) قادم من قاعدة البيانات.
/// [accountId] قد يكون null للعمليات غير المربوطة بحساب.
class CardAccountBreakdownRow {
  const CardAccountBreakdownRow({
    required this.last4,
    required this.currency,
    required this.accountId,
    required this.totalIn,
    required this.totalOut,
    required this.count,
    required this.sample,
    this.colorTheme,
    this.accentHex,
  });

  final String last4;

  /// عملة هذا الصف (MALI-074n) — لا تُدمج عملتان في بطاقة واحدة.
  final String currency;
  final String? accountId;

  /// الدخل فقط (income). صافي الإنفاق في [totalOut] (الاسترداد يخصم منه).
  final Money totalIn;
  final Money totalOut;
  final int count;
  final String sample;

  /// تصميم البطاقة اليدوية المطابقة (من جدول cards) إن وُجدت.
  final String? colorTheme;
  final String? accentHex;
}

/// نتيجة تجميع البطاقات: بطاقات مربوطة بثقة بحساب معيّن، وبطاقات غير مخصّصة.
class CardGrouping {
  const CardGrouping({
    required this.byAccount,
    required this.unassigned,
  });

  /// accountId → بطاقات هذا الحساب.
  final Map<String, List<CardSummary>> byAccount;

  /// بطاقات ظهرت في الرسائل لكن بلا حساب موثوق.
  final List<CardSummary> unassigned;
}

/// عتبة الثقة لربط بطاقة بحساب: 1.0 = يجب أن يكون حساب واحد فقط هو صاحب كل
/// العمليات المربوطة بحساب لتلك البطاقة (أي خلاف بين حسابين → غير مخصّصة).
/// SMS-first: كثير من البطاقات قد تبقى غير مخصّصة، وهذا سلوك متوقّع — لا نفرض
/// حسابًا بناءً على افتراض ضعيف.
const double kCardAccountConfidence = 1.0;

/// منطق نقي (بدون I/O) لتحويل صفوف الـ breakdown إلى تجميع بطاقات حسب الحساب.
/// لا يكتب أبدًا `account_id` — يقرأ فقط ما هو موجود على العمليات.
class CardAccountGrouper {
  const CardAccountGrouper({this.confidence = kCardAccountConfidence});

  final double confidence;

  CardGrouping group(List<CardAccountBreakdownRow> rows) {
    // MALI-074n: group by (last4, currency) so two currencies on one card never
    // merge into a single cross-currency summary.
    final byCard = <String, List<CardAccountBreakdownRow>>{};
    for (final row in rows) {
      byCard.putIfAbsent('${row.last4}|${row.currency}', () => []).add(row);
    }

    final byAccount = <String, List<CardSummary>>{};
    final unassigned = <CardSummary>[];

    for (final cardRows in byCard.values) {
      final summary =
          _summaryFor(cardRows.first.last4, cardRows.first.currency, cardRows);
      final owner = _confidentOwner(cardRows);
      if (owner == null) {
        unassigned.add(summary);
      } else {
        byAccount.putIfAbsent(owner, () => []).add(summary);
      }
    }

    return CardGrouping(byAccount: byAccount, unassigned: unassigned);
  }

  CardSummary _summaryFor(
      String last4, String currency, List<CardAccountBreakdownRow> rows) {
    var totalIn = Money(0, currency);
    var totalOut = Money(0, currency);
    var count = 0;
    var sample = '';
    String? colorTheme;
    String? accentHex;
    for (final row in rows) {
      totalIn = totalIn + row.totalIn;
      totalOut = totalOut + row.totalOut;
      count += row.count;
      if (sample.isEmpty && row.sample.isNotEmpty) sample = row.sample;
      colorTheme ??= row.colorTheme;
      accentHex ??= row.accentHex;
    }
    return CardSummary(
      last4: last4,
      currency: currency,
      network: CardNetworkDetector.detect(sample),
      totalOut: totalOut,
      totalIn: totalIn,
      count: count,
      colorTheme: colorTheme,
      accentHex: accentHex,
    );
  }

  /// الحساب صاحب البطاقة إن وُجد بثقة، وإلا null.
  String? _confidentOwner(List<CardAccountBreakdownRow> rows) {
    final counts = <String, int>{};
    for (final row in rows) {
      final accountId = row.accountId;
      if (accountId == null) continue;
      counts[accountId] = (counts[accountId] ?? 0) + row.count;
    }
    if (counts.isEmpty) return null; // لا حساب على أي عملية → غير مخصّصة.
    if (counts.length == 1) return counts.keys.first; // اتفاق كامل.

    // حسابان أو أكثر يتنافسان: يُربط فقط إذا تجاوز المهيمن العتبة.
    final total = counts.values.fold<int>(0, (sum, c) => sum + c);
    final dominant =
        counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final share = dominant.value / total;
    return share >= confidence ? dominant.key : null;
  }
}
