/// MALI-026 (Phase-8 B8-2 §6/§7) — the SINGLE exact Supabase NUMERIC transport
/// serializer. Decimal conversion for the wire lives ONLY here (never scattered).
///
///   PUSH  Money → exact decimal String  → NUMERIC column.
///   PULL  `amount::text` JSON String → Money.parse (no `double` on the path).
///
/// PUSH activation status: READY_EXACT_NOT_ACTIVATED. Sending a decimal STRING to
/// a NUMERIC column is a request-shape change whose acceptance has not been
/// exercised against the live server, so it is NOT activated yet ([moneyToNumericText]
/// exists and is tested, but the push services keep emitting the current
/// JSON-number shape via [moneyToLegacyJsonNumber], derived exactly from Money). End-to-end
/// sync exactness stays external-pending until proven in staging.
library;

import 'money.dart';

/// Thrown when a pulled canonical money value is not the expected decimal String
/// (e.g. the `::text` projection was not applied) — fail explicitly, NEVER fall
/// back to a silent `.toDouble()` (§6).
class MoneyTransportException implements Exception {
  const MoneyTransportException(this.message);
  final String message;
  @override
  String toString() => 'MoneyTransportException: $message';
}

/// PUSH (exact, READY_EXACT_NOT_ACTIVATED): the canonical decimal String for a
/// NUMERIC column. Byte-exact, no binary `double`.
String moneyToNumericText(Money m) => m.toDecimalString();

/// PUSH (LEGACY compatibility shape — READY_EXACT_NOT_ACTIVATED era): the JSON
/// number for the EXISTING request shape, derived from canonical minor units.
///
/// This is a LEGACY compatibility adapter, deliberately named so it can never be
/// mistaken for the canonical/exact end state. It is lossy beyond 2^53 minor
/// units and must be replaced by exact decimal-string NUMERIC transport (or
/// another proven no-double transport) before Phase-8 closure. A pulled/received
/// value must NEVER be reconstructed into canonical Money from this path.
num moneyToLegacyJsonNumber(Money m) => m.toDouble();

/// PULL: parse a `::text` NUMERIC response value into exact [Money]. The value
/// MUST be a decimal String (from `select=amount::text`) or `null`; any other
/// runtime type (e.g. a JSON number, meaning the cast was not applied) throws
/// rather than silently degrading to a `double`.
Money? moneyFromPulledValue(Object? raw, String currency) {
  if (raw == null) return null;
  if (raw is String) return Money.parse(raw, currency);
  throw MoneyTransportException(
      'expected a NUMERIC::text String for canonical money, got '
      '${raw.runtimeType} ($raw) — the ::text projection was not applied');
}

/// PULL, non-null: like [moneyFromPulledValue] but the money is required.
Money moneyFromPulledValueRequired(Object? raw, String currency) {
  final m = moneyFromPulledValue(raw, currency);
  if (m == null) {
    throw const MoneyTransportException('required canonical money was null');
  }
  return m;
}
