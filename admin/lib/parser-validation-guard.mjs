/**
 * F-011 — a parser rule must not become trusted by having a label typed on it.
 *
 * `validation_status = 'passed'` is not a description, it is an AUTHORITY. C-1
 * established what it buys: a passed catalog rule is served to clients and
 * carries the high confidence that lets a parsed transaction be auto-confirmed
 * as real money. So "passed" has to mean "a golden-test run proved it", and the
 * admin edit route accepted it as a plain field from the request body:
 *
 *     validation_status: input.validation_status,
 *
 * Anyone able to reach that route could promote an unvalidated regex to
 * money-writing authority by setting one string.
 *
 * ## The rule enforced here
 *
 * Promotion to `passed` is NOT an editing operation. Only the `parser-test`
 * Edge Function — which actually runs the golden corpus and writes the evidence
 * columns in the same statement — may set it. An admin edit may:
 *
 *   * leave the status untouched,
 *   * DEMOTE (`passed` → `pending`/`failed`), which is always safe because it
 *     removes authority rather than granting it,
 *
 * and may never promote. That asymmetry is the whole design: a mistaken demotion
 * costs a re-run of the tests, a mistaken promotion ships an unvalidated regex
 * that writes confirmed money.
 *
 * Evidence-bearing columns (`validated_at`, `golden_test_count`, `passed_count`)
 * are likewise refused from client input, because accepting them would let a
 * caller manufacture the evidence the promotion rule checks for.
 *
 * This is defence in depth, not the only line: migration
 * `0087_parser_validation_evidence.sql` adds a CHECK that makes an evidence-free
 * `passed` row unrepresentable in the database. The guard exists so the refusal
 * happens at the boundary with a comprehensible error, rather than surfacing as
 * a raw constraint violation — and so the rule still holds on any deployment
 * where 0087 has not yet been applied.
 */

export const VALID_STATUSES = ['pending', 'failed', 'passed'];

/** Columns only a real test run may write. */
export const EVIDENCE_COLUMNS = [
  'validated_at',
  'golden_test_count',
  'passed_count',
];

export class ParserValidationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ParserValidationError';
    this.code = code;
  }
}

/**
 * Returns the sanitised patch to apply, or throws ParserValidationError.
 *
 * @param {object} input      the caller-supplied row
 * @param {object|null} existing  the current DB row (null when creating)
 */
export function guardParserWrite(input, existing = null) {
  const patch = { ...input };

  for (const col of EVIDENCE_COLUMNS) {
    if (col in patch) {
      throw new ParserValidationError(
        'evidence_not_client_writable',
        `"${col}" records the result of a golden-test run and cannot be set ` +
          `by an edit. Run the parser test to produce it.`,
      );
    }
  }

  if (!('validation_status' in patch) || patch.validation_status == null) {
    return patch;
  }

  const next = String(patch.validation_status);
  if (!VALID_STATUSES.includes(next)) {
    throw new ParserValidationError(
      'invalid_validation_status',
      `"${next}" is not a validation status (${VALID_STATUSES.join(', ')}).`,
    );
  }

  const current = existing?.validation_status ?? 'pending';

  if (next === 'passed' && current !== 'passed') {
    throw new ParserValidationError(
      'promotion_requires_test_run',
      'A rule becomes "passed" only by passing its golden tests — run the ' +
        'parser test. Setting the label directly would grant an unvalidated ' +
        'regex the authority to auto-confirm money.',
    );
  }

  // Re-asserting `passed` on a row that is ALREADY passed is a no-op, but only
  // if the evidence is really there. A row that reached `passed` before the
  // evidence rule existed must not have that status laundered forward by an
  // unrelated edit.
  if (next === 'passed' && current === 'passed' && !hasEvidence(existing)) {
    throw new ParserValidationError(
      'passed_without_evidence',
      'This rule is marked "passed" but carries no golden-test evidence. ' +
        'Re-run the parser test; the status cannot be preserved on an edit.',
    );
  }

  return patch;
}

/** Whether a row carries real golden-test evidence. */
export function hasEvidence(row) {
  if (!row) return false;
  const count = Number(row.golden_test_count ?? 0);
  return Boolean(row.validated_at) && Number.isFinite(count) && count > 0;
}

/**
 * Whether a rule may be SERVED to clients as trusted.
 *
 * Mirrors the client-side cap from C-1: the catalog must not deliver a rule as
 * high-confidence unless the evidence exists, regardless of the label.
 */
export function mayServeAsTrusted(row) {
  return row?.validation_status === 'passed' && hasEvidence(row);
}
