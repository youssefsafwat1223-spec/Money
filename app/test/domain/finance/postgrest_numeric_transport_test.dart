import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (Phase-8 B8-0) — PostgREST NUMERIC transport PROOF (Decision 4 /
// Correction A).
//
// The money push paths are DIRECT PostgREST table upserts/inserts to NUMERIC
// columns (ledger/planning/accounts `.upsert`, backfill `.insert`). The
// PostgREST client (postgrest 2.7.1) serialises the request body with
// `json.encode` — the exact mechanism proven here. Sending the amount as the
// exact decimal STRING derived from canonical minor units (`Money.toDecimalString`)
// puts a byte-exact string in the HTTP body with NO binary `double` on the path;
// a Dart `double`, by contrast, is emitted as a JSON number (the imprecise path
// we are eliminating).
//
// The server accepting a JSON decimal string into a NUMERIC column is standard
// PostgREST/Postgres text-cast behaviour and is the EXTERNAL (live-backend) half
// of this proof.

void main() {
  test('exact decimal STRING (Option C) is json-encoded byte-exact — no double',
      () {
    final body = json.encode({
      'amount': Money(1999, 'EGP').toDecimalString(), // "19.99"
      'balance_after': Money(-50, 'EGP').toDecimalString(), // "-0.50"
    });
    expect(body, contains('"amount":"19.99"'));
    expect(body, contains('"balance_after":"-0.50"'));
    // No JSON number for these money fields → no binary-double on the wire path.
    expect(body.contains('"amount":19.99'), isFalse);
  });

  test('3-decimal + 0-decimal currencies transport exactly as strings', () {
    expect(json.encode({'amount': Money(1234, 'KWD').toDecimalString()}),
        contains('"amount":"1.234"'));
    expect(json.encode({'amount': Money(1234, 'JPY').toDecimalString()}),
        contains('"amount":"1234"'));
  });

  test('CONTRAST: a Dart double is emitted as a JSON number (the imprecise path)',
      () {
    // 0.1 + 0.2 as a double is 0.30000000000000004; json.encode keeps the float.
    final body = json.encode({'amount': 0.1 + 0.2});
    expect(body, contains('0.30000000000000004'));
    // Whereas the canonical minor-unit string is exact:
    expect(
        json.encode({'amount': Money(30, 'EGP').toDecimalString()}), // "0.30"
        contains('"amount":"0.30"'));
  });
}
