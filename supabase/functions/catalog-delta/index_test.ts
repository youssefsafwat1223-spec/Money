import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { isValidCountryParam } from './index.ts';

// H2: the `country` query param used to be interpolated unsanitized into a
// PostgREST `.or()` filter string for merchant_keywords
// (`country_code.eq.ALL,country_code.eq.${country}`) — a crafted value with
// commas/operators could manipulate the filter. isValidCountryParam is the
// gate the handler now runs before building any filter at all.

Deno.test('accepts a valid 2-letter uppercase country code', () => {
  assertEquals(isValidCountryParam('SA'), true);
});

Deno.test('accepts a valid 3-letter uppercase country code', () => {
  assertEquals(isValidCountryParam('EGY'), true);
});

Deno.test('rejects lowercase — the caller must normalize before calling',
  () => {
    // The handler itself upper-cases before validating (see index.ts); this
    // documents that the predicate is intentionally case-sensitive rather
    // than silently accepting anything.
    assertEquals(isValidCountryParam('sa'), false);
  });

Deno.test('rejects a comma/operator-injection attempt', () => {
  assertEquals(
    isValidCountryParam('US,or(is_deleted.eq.false'),
    false,
  );
});

Deno.test('rejects an empty string', () => {
  assertEquals(isValidCountryParam(''), false);
});

Deno.test('rejects an overlong value', () => {
  assertEquals(isValidCountryParam('A'.repeat(50)), false);
});

Deno.test('rejects a single-character value', () => {
  assertEquals(isValidCountryParam('A'), false);
});

Deno.test('rejects a value with digits', () => {
  assertEquals(isValidCountryParam('S4'), false);
});
