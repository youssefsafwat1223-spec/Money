import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { validateEvidenceSpans } from './evidence_spans.ts';

// The text the server would actually send upstream, redactions already applied.
const TEXT = 'Purchase [CARD] SAR 45.00';

function reason(evidence: unknown, text = TEXT): string | true {
  const r = validateEvidenceSpans(evidence, text);
  return r.ok ? true : r.reason;
}

Deno.test('a span that quotes its own text is accepted', () => {
  assertEquals(reason([{ s: 20, e: 25, t: '45.00' }]), true);
});

Deno.test('a STALE span is rejected — the whole point of the gate', () => {
  // Well-formed integers, plausible text, wrong characters. This is exactly
  // what a client/server sanitizer skew produces, and it must never pass.
  assertEquals(reason([{ s: 0, e: 5, t: '45.00' }]), 'evidence_span_stale');
});

Deno.test('spans overlapping a redaction placeholder are rejected', () => {
  // `[CARD]` is not evidence. Evidence claiming to be it is confused or hostile.
  assertEquals(
    reason([{ s: 9, e: 15, t: '[CARD]' }]),
    'evidence_span_overlaps_redaction',
  );
});

Deno.test('out-of-range and inverted spans are rejected', () => {
  assertEquals(reason([{ s: 0, e: 999, t: 'x' }]), 'evidence_span_out_of_range');
  assertEquals(reason([{ s: 5, e: 2, t: 'x' }]), 'evidence_span_out_of_range');
  assertEquals(reason([{ s: -1, e: 3, t: 'x' }]), 'evidence_span_out_of_range');
  assertEquals(reason([{ s: 3, e: 3, t: '' }]), 'evidence_span_out_of_range');
});

Deno.test('malformed payloads are rejected, not coerced', () => {
  assertEquals(reason([{ s: '0', e: 5, t: 'x' }]), 'evidence_span_malformed');
  assertEquals(reason([{ s: 0, e: 5 }]), 'evidence_span_malformed');
  assertEquals(reason([{ s: 0.5, e: 5, t: 'x' }]), 'evidence_span_not_integer');
  assertEquals(reason([null]), 'evidence_node_not_object');
  assertEquals(reason('nope'), 'evidence_not_array');
});

Deno.test('absent evidence is allowed — forward compatible', () => {
  // Spans do not flow yet. The gate must not break the current contract, but
  // must be enforced the moment they start.
  assertEquals(reason(undefined), true);
  assertEquals(reason(null), true);
  assertEquals(reason([]), true);
});

Deno.test('an unbounded evidence array is refused', () => {
  const many = new Array(65).fill({ s: 20, e: 25, t: '45.00' });
  assertEquals(reason(many), 'evidence_too_many');
});

Deno.test('start/end and s/e spellings are both accepted', () => {
  assertEquals(reason([{ start: 20, end: 25, text: '45.00' }]), true);
});

Deno.test('one bad span rejects the whole payload', () => {
  // Partial acceptance would mean proving from a set that was partly verified.
  assertEquals(
    reason([{ s: 20, e: 25, t: '45.00' }, { s: 0, e: 5, t: '45.00' }]),
    'evidence_span_stale',
  );
});

Deno.test('Arabic and emoji spans verify by code unit', () => {
  const arabic = 'شراء 45.00 ر.س';
  assertEquals(
    validateEvidenceSpans([{ s: arabic.indexOf('45.00'), e: arabic.indexOf('45.00') + 5, t: '45.00' }], arabic).ok,
    true,
  );
  const emoji = '🎉 SAR 45.00';
  const at = emoji.indexOf('45.00');
  assertEquals(validateEvidenceSpans([{ s: at, e: at + 5, t: '45.00' }], emoji).ok, true);
  // An offset computed as if the emoji were one unit rather than two.
  assertEquals(
    validateEvidenceSpans([{ s: at - 1, e: at + 4, t: '45.00' }], emoji).ok,
    false,
  );
});
