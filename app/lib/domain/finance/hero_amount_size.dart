/// UX-035 — a legibility FLOOR for the large statement figures.
///
/// The report: *"very large values on the cards UI collapse into a zero-like /
/// unreadable visual result («0 0 0»)"*, filed HIGH and NEEDS REPRO.
///
/// The finding has two halves, and only one of them is a rendering problem.
///
/// **The exactness half is a real defect and is fixed.** Every statement figure
/// used to be formatted as `Formatters.amount(money.toDouble())`. Past 2^53 a
/// `double` cannot represent consecutive integers, so the digits printed were
/// not the digits stored — the "silently rounding to zero" the finding
/// describes, in its literal form. Those surfaces now format from exact minor
/// units (`money_format.dart` / `MoneyText`), so the digits are right at any
/// magnitude.
///
/// **The legibility half is this file.** The hero amount sits in a
/// `FittedBox(fit: BoxFit.scaleDown)`, chosen deliberately so a financial figure
/// is never truncated. But `scaleDown` has no floor: the longer the value, the
/// smaller it renders, with nothing stopping it before it becomes a row of
/// indistinct marks — which is exactly what "«0 0 0»" describes at a glance.
///
/// Picking the size from the value's LENGTH gives that floor deterministically,
/// with no layout measurement and no redesign: long values step down through
/// legible sizes instead of shrinking continuously toward nothing. The
/// `FittedBox` stays as the final safety net for the extreme case, so nothing
/// is truncated either.
///
/// The thresholds are digit counts of the FORMATTED string (including grouping
/// separators and the decimal part), because that is what actually occupies
/// width.
///
/// **Residual limitation, stated precisely:** the original defect was reported
/// from a device and the repro — exact value, locale, screen, font scaling,
/// screenshot — was never captured, so this cannot be verified against the
/// original sighting. What is verified here is that exact large values keep
/// every significant digit and that the hero has a legibility floor. If the
/// device repro is later captured and shows a different cause, this is the
/// wrong fix rather than an incomplete one.
library;

/// Font size for a hero statement amount of [formattedLength] characters.
///
/// [base] is the size the surface wants for an ordinary value; the returned
/// size is never larger than it and never below the legibility floor.
double heroAmountFontSize(int formattedLength, {double base = 40}) {
  // 9 chars ≈ "12,345.67" — the common case, unchanged.
  if (formattedLength <= 9) return base;
  // 13 chars ≈ "1,234,567.89" — millions.
  if (formattedLength <= 13) return base * 0.80;
  // 17 chars ≈ "1,234,567,890.12" — billions.
  if (formattedLength <= 17) return base * 0.65;
  // Beyond that the FittedBox takes over, from a size that is still readable
  // rather than from one already scaled past recognition.
  return base * 0.55;
}
