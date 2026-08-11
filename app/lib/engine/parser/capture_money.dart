import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';

/// How a parsed AI/capture amount may enter financial authority.
enum AiCaptureIngress {
  /// Future canonical mode received the verified exact text field.
  canonicalExact,

  /// Future canonical mode received only the legacy numeric field; review is
  /// required and the value cannot auto-confirm into canonical authority.
  legacyPendingReview,
}

/// Resolves old/new backend response shapes without interpreting the amount.
///
/// In canonical mode an exact text field is mandatory. A numeric-only response
/// must use [legacyLossyNumberToMoney] and the existing pending-review path.
AiCaptureIngress resolveAiCaptureIngress({
  required bool hasExactText,
  required bool canonicalMode,
}) {
  if (canonicalMode && !hasExactText) {
    return AiCaptureIngress.legacyPendingReview;
  }
  // v29 already prefers exact text and routes numeric-only legacy values to
  // pending review, so the same shape-based result preserves current behavior.
  return hasExactText
      ? AiCaptureIngress.canonicalExact
      : AiCaptureIngress.legacyPendingReview;
}

/// EXACT machine/capture money parse. The required normalization semantics are
/// IDENTICAL to the UI adapter (Arabic-Indic/Persian digits -> ASCII, U+066B ->
/// '.', structurally-valid thousands grouping only; "12,50" and any ambiguous
/// comma REJECTED; over-precision beyond the currency scale REJECTED), so it
/// deliberately reuses parseLocalizedMoney rather than inventing a second
/// normalizer. Bank tokens that carry MORE fractional precision than the
/// currency scale, or an ambiguous/unsupported token, THROW -> the caller must
/// route the transaction to a review/pending path (NEVER silently round a
/// bank-reported amount).
Money parseCaptureMoney(String token, String currency) =>
    parseLocalizedMoney(token, currency);

/// LEGACY-LOSSY compatibility ONLY: a numeric value that was already decoded as
/// a JSON number (AI / capture Edge-function responses from a backend that does
/// NOT yet send an exact `*_text` field) has already lost precision before we
/// see it. This is the explicitly-named legacy path — it is NOT exact and must
/// be flagged LEGACY_LOSSY, never presented as canonical Phase-8 ingress.
Money legacyLossyNumberToMoney(num value, String currency) =>
    Money.fromLegacyReal(value.toDouble(), currency);
