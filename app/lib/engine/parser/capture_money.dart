import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';

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
