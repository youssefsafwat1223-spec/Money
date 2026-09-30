import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type AiCandidate,
  type LocalCandidate,
  validateAiCandidate,
} from './ai_candidate_validator.ts';
import cases from './fixtures/ai_candidate_cases.json' with { type: 'json' };

// The SAME file is run through the app's AiCandidateValidator by
// app/test/engine/ai/ai_candidate_shared_fixtures_test.dart. Do not weaken a
// case here to make one side pass; a real disagreement must be reported.
//
// Deliberate server-only strictness NOT in the shared file (spec-mandated):
// currency whitelist, AI `direction` field contradiction, amount/amount_text
// agreement, ASCII-only canonical amount_text.

for (const c of cases as Array<{
  name: string;
  sanitized_text: string;
  received_at: string;
  local: LocalCandidate | null;
  ai: AiCandidate;
  expected: {
    accepted: boolean;
    reason?: string;
    currency?: string;
    merchant?: string | null;
    occurred_at_kept?: boolean;
  };
}>) {
  Deno.test(`shared AI candidate fixture: ${c.name}`, () => {
    const out = validateAiCandidate({
      candidate: c.ai,
      sanitizedText: c.sanitized_text,
      receivedAt: c.received_at,
      local: c.local,
    });
    assertEquals(out.accepted, c.expected.accepted);
    if (!out.accepted) {
      assertEquals(out.reason, c.expected.reason);
    } else {
      assertEquals(out.currency, c.expected.currency);
      assertEquals(out.merchant, c.expected.merchant ?? null);
      assertEquals(out.occurredAt != null, c.expected.occurred_at_kept ?? false);
    }
  });
}

Deno.test('server-only: currency outside the whitelist is rejected even when grounded', () => {
  const out = validateAiCandidate({
    candidate: { amount: 75, amount_text: '75.00', currency: 'INR' },
    sanitizedText: 'Paid 75.00 INR at SHOP',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'currency_not_whitelisted' });
});

Deno.test('server-only: AI direction field contradicting wording is rejected', () => {
  const out = validateAiCandidate({
    candidate: { amount: 500, amount_text: '500.00', currency: 'EGP', type: 'unknown', direction: 'debit' },
    sanitizedText: 'تم إيداع 500.00 EGP في حسابك',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'direction_contradiction' });
});

Deno.test('server-only: amount and amount_text must agree', () => {
  const out = validateAiCandidate({
    candidate: { amount: 75, amount_text: '750.00', currency: 'SAR' },
    sanitizedText: 'Paid 75.00 SAR / 750.00 SAR',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'amount_text_mismatch' });
});

Deno.test('AI confidence is not part of the candidate contract', () => {
  const base = { amount: 75, amount_text: '75.00', currency: 'SAR' };
  const text = 'Paid 75.00 SAR at SHOP';
  const run = (confidence: number) =>
    validateAiCandidate({
      candidate: { ...base, confidence } as AiCandidate,
      sanitizedText: text,
      receivedAt: '2026-06-16T12:00:00Z',
      local: null,
    });
  assertEquals(run(0.01), run(0.99));
});
