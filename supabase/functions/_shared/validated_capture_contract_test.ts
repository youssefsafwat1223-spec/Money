import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { last4Grounded, merchantGrounded, validateAiCandidate } from './ai_candidate_validator.ts';
import fixture from '../../../contract_fixtures/validated_capture_v1.json' with { type: 'json' };

// ValidatedCapture v1, validator-level contract. The same file is consumed by
// the Dart tests; do not weaken a case to make one side pass.
const RECEIVED_AT = '2026-06-16T12:00:00Z';

Deno.test('validated_capture_v1 fixture version', () => {
  assertEquals(fixture.version, 1);
});

for (const c of fixture.cases as Array<{
  id: string;
  text: string;
  candidate: {
    amount: number;
    amount_text: string;
    currency: string;
    direction: string;
    merchant?: string;
    last4?: string;
    occurred_at?: string;
  };
  expected: { valid: boolean; reason?: string; kept_fields?: string[] };
}>) {
  Deno.test(`validated_capture_v1: ${c.id}`, () => {
    const out = validateAiCandidate({
      candidate: c.candidate,
      sanitizedText: c.text,
      receivedAt: RECEIVED_AT,
      local: null,
    });
    assertEquals(out.accepted, c.expected.valid);
    if (!out.accepted) {
      assertEquals(out.reason, c.expected.reason);
      return;
    }
    const kept: string[] = [];
    if (merchantGrounded(c.candidate.merchant, c.text)) kept.push('merchant');
    if (last4Grounded(c.candidate.last4, c.text)) kept.push('last4');
    if (out.occurredAt != null) kept.push('occurred_at');
    assertEquals(kept, c.expected.kept_fields ?? []);
  });
}
