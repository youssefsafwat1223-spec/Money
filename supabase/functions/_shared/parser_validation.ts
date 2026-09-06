// Parser golden-test validation — the promotion contract.
//
// `validation_status = 'passed'` is an AUTHORITY: a passed rule is served to
// devices and its captured amount can become confirmed money. The previous
// validator checked only match/no-match plus amount, while recording currency
// and type it never compared. So "passed" meant "the regex found the right
// number in the messages someone chose" — materially weaker than the label
// implies, and weaker than the `extracted_fields` contract the rule declares.
//
// TWO PROBLEMS, FIXED TOGETHER.
//
// 1. FIELD COVERAGE. Every field the rule's own `extracted_fields` claims to
//    produce is now compared against the golden row's expectation, wherever
//    that expectation exists. Missing expectation is NOT silent success: a row
//    that expects nothing at all cannot count toward the applicable-positive
//    coverage a promotion requires.
//
// 2. APPLICABILITY. Golden rows were loaded by `bank_id` alone, so a salary or
//    refund message for the same bank made a debit-only rule fail as a
//    `false_negative`. The only way to pass was to curate a debit-only corpus —
//    which is exactly the curation that makes validation vacuous. Rows are now
//    classified against the rule's own scope:
//
//      APPLICABLE POSITIVE  the row's class is the rule's class
//                           -> must match, and every claimed field must agree
//      APPLICABLE NEGATIVE  the row is 'ignored' (OTP, promo, noise)
//                           -> must not match
//      OUT OF SCOPE         same bank, different class (credit/reversal/...)
//                           -> a non-match is CORRECT and not a failure, but a
//                              match is a FALSE POSITIVE: a debit rule that
//                              fires on a salary message writes money in the
//                              wrong direction.
//
//    So an out-of-scope row still carries real signal; it simply cannot fail
//    the rule for declining to match.

/** The transaction classes a golden row may declare. */
export type GoldenClass = string;

export interface GoldenRow {
  readonly id: string;
  readonly sender: string;
  readonly message_text: string;
  /** The row's TRUE class: the rule's class, another class, or 'ignored'. */
  readonly expected_type: GoldenClass;
  readonly expected_amount: number | null;
  readonly expected_currency: string | null;
  readonly expected_merchant: string | null;
  readonly is_otp?: boolean;
  readonly is_promo?: boolean;
  /** Optional: pins the row to ONE rule rather than the whole bank. */
  readonly parser_id?: string | null;
}

export interface RuleUnderTest {
  readonly id: string;
  readonly sender_pattern: string;
  readonly message_pattern: string;
  /** 'debit' | 'credit' | 'balance_inquiry' — the rule's declared scope. */
  readonly transaction_type: string;
  /** field name -> capture group, or a literal for 'type'/'currency'. */
  readonly extracted_fields: Record<string, unknown>;
}

export type Applicability = 'positive' | 'negative' | 'out_of_scope';

export type FailureKind =
  | 'false_positive'
  | 'false_negative'
  | 'out_of_scope_match'
  | 'amount_mismatch'
  | 'amount_not_extracted'
  | 'currency_mismatch'
  | 'merchant_mismatch'
  | 'type_mismatch'
  | 'sender_scope_mismatch'
  | 'invalid_pattern';

export interface RowResult {
  readonly test_id: string;
  readonly applicability: Applicability;
  readonly matched: boolean;
  readonly passed: boolean;
  readonly failure_kind?: FailureKind;
  readonly detail?: string;
  readonly checked_fields: string[];
}

export interface Verdict {
  readonly status: 'passed' | 'failed';
  readonly reason?: string;
  readonly results: RowResult[];
  /** Rows that actually exercised the rule's own class. */
  readonly applicable_positive_count: number;
  readonly applicable_negative_count: number;
  readonly out_of_scope_count: number;
  /** What `golden_test_count` should record: rows that carried real signal. */
  readonly golden_test_count: number;
  readonly false_positive_count: number;
  readonly amount_error_count: number;
}

/** Promotion requires at least this many applicable positives. */
export const MIN_APPLICABLE_POSITIVES = 1;

/** A row is 'ignored' when it declares that class or is flagged OTP/promo. */
function isIgnored(row: GoldenRow): boolean {
  return row.expected_type === 'ignored' ||
    row.is_otp === true || row.is_promo === true;
}

export function classify(rule: RuleUnderTest, row: GoldenRow): Applicability {
  if (isIgnored(row)) return 'negative';
  return row.expected_type === rule.transaction_type ? 'positive' : 'out_of_scope';
}

/** Which rows belong to this rule at all. */
export function appliesToRule(rule: RuleUnderTest, row: GoldenRow): boolean {
  // A row pinned to another rule is not this rule's evidence.
  return row.parser_id == null || row.parser_id === rule.id;
}

/** Money text -> number, tolerating thousands separators. Never rounds. */
function toNumber(text: string | undefined): number | null {
  if (text === undefined) return null;
  const cleaned = text.replace(/,/g, '').trim();
  if (cleaned === '') return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? n : null;
}

/** Comparison for merchant/currency: case- and whitespace-insensitive. */
function loose(a: string): string {
  return a.trim().replace(/\s+/g, ' ').toLowerCase();
}

/**
 * The value a rule claims for a field: a capture group, or a literal.
 *
 * `extracted_fields` maps a field name to EITHER a named capture group or a
 * fixed value (SA rules declare `"currency": "SAR"`, and every rule declares
 * `"type": "debit"`). Both are claims, so both are checked.
 */
function claimedValue(
  rule: RuleUnderTest,
  field: string,
  groups: Record<string, string | undefined>,
): string | null {
  const claim = rule.extracted_fields[field];
  if (typeof claim !== 'string') return null;
  if (Object.prototype.hasOwnProperty.call(groups, claim)) {
    return groups[claim] ?? null;
  }
  // Not a group name -> a literal the rule asserts for every match.
  return claim;
}

export function evaluateRow(rule: RuleUnderTest, row: GoldenRow): RowResult {
  const applicability = classify(rule, row);
  const checked: string[] = [];

  let senderRe: RegExp;
  let messageRe: RegExp;
  try {
    // 'i' to match the DEVICE. catalog_rule_matcher.dart compiles both
    // patterns with caseSensitive: false, and the validator this replaced used
    // the same flag. Without it, negative and out-of-scope rows were FAIL-OPEN:
    // a promo the device matches on 'purchase'/'at' does not match here, so the
    // run certified an ignore that will not happen in production.
    senderRe = new RegExp(rule.sender_pattern, 'i');
    messageRe = new RegExp(rule.message_pattern, 'i');
  } catch (_e) {
    return {
      test_id: row.id,
      applicability,
      matched: false,
      passed: false,
      failure_kind: 'invalid_pattern',
      detail: 'the rule does not compile',
      checked_fields: checked,
    };
  }

  const senderOk = senderRe.test(row.sender);
  const msgMatch = senderOk ? messageRe.exec(row.message_text) : null;
  const matched = msgMatch !== null;

  // ── Negative: must not match ────────────────────────────────────────────
  if (applicability === 'negative') {
    return {
      test_id: row.id,
      applicability,
      matched,
      passed: !matched,
      failure_kind: matched ? 'false_positive' : undefined,
      detail: matched ? 'matched a message it must ignore' : undefined,
      checked_fields: checked,
    };
  }

  // ── Out of scope: a non-match is correct; a match is a false positive ───
  if (applicability === 'out_of_scope') {
    return {
      test_id: row.id,
      applicability,
      matched,
      passed: !matched,
      failure_kind: matched ? 'out_of_scope_match' : undefined,
      detail: matched
        ? `a ${rule.transaction_type} rule matched a ${row.expected_type} message`
        : undefined,
      checked_fields: checked,
    };
  }

  // ── Applicable positive: must match, and every claim must hold ──────────
  if (!senderOk) {
    return {
      test_id: row.id,
      applicability,
      matched: false,
      passed: false,
      failure_kind: 'sender_scope_mismatch',
      detail: 'the rule does not claim this sender',
      checked_fields: checked,
    };
  }
  if (!matched) {
    return {
      test_id: row.id,
      applicability,
      matched: false,
      passed: false,
      failure_kind: 'false_negative',
      checked_fields: checked,
    };
  }

  const groups = (msgMatch.groups ?? {}) as Record<string, string | undefined>;
  const fail = (kind: FailureKind, detail: string): RowResult => ({
    test_id: row.id,
    applicability,
    matched: true,
    passed: false,
    failure_kind: kind,
    detail,
    checked_fields: checked,
  });

  // AMOUNT — exact to the financial tolerance already used by this validator.
  if (rule.extracted_fields['amount'] !== undefined && row.expected_amount !== null) {
    checked.push('amount');
    const got = toNumber(claimedValue(rule, 'amount', groups) ?? undefined);
    if (got === null) {
      return fail('amount_not_extracted', 'expected an amount, captured none');
    }
    if (Math.abs(got - row.expected_amount) > 0.001) {
      return fail('amount_mismatch', `expected ${row.expected_amount}, captured ${got}`);
    }
  }

  // CURRENCY — the rule claims one, either captured or literal.
  if (rule.extracted_fields['currency'] !== undefined && row.expected_currency !== null) {
    checked.push('currency');
    const got = claimedValue(rule, 'currency', groups);
    if (got === null || loose(got) !== loose(row.expected_currency)) {
      return fail('currency_mismatch', `expected ${row.expected_currency}, got ${got}`);
    }
  }

  // TYPE / DIRECTION — the rule's declared class must equal the row's class.
  if (rule.extracted_fields['type'] !== undefined) {
    checked.push('type');
    const got = claimedValue(rule, 'type', groups) ?? rule.transaction_type;
    if (loose(got) !== loose(row.expected_type)) {
      return fail('type_mismatch', `expected ${row.expected_type}, rule claims ${got}`);
    }
  }

  // MERCHANT — only when the row states one.
  if (rule.extracted_fields['merchant'] !== undefined && row.expected_merchant !== null) {
    checked.push('merchant');
    const got = claimedValue(rule, 'merchant', groups);
    if (got === null || loose(got) !== loose(row.expected_merchant)) {
      return fail('merchant_mismatch', `expected ${row.expected_merchant}, got ${got}`);
    }
  }

  return {
    test_id: row.id,
    applicability,
    matched: true,
    passed: true,
    checked_fields: checked,
  };
}

export function validateParser(rule: RuleUnderTest, rows: GoldenRow[]): Verdict {
  const mine = rows.filter((r) => appliesToRule(rule, r));
  const results = mine.map((r) => evaluateRow(rule, r));

  const positives = results.filter((r) => r.applicability === 'positive');
  const negatives = results.filter((r) => r.applicability === 'negative');
  const outOfScope = results.filter((r) => r.applicability === 'out_of_scope');

  // Only rows that verified something count as evidence, and 'evidence' has to
  // mean the MONEY. Two weaker notions were tried and are wrong:
  //   * 'type' alone is derived from the rule's own declaration and the row's
  //     class, so it holds for any matching message; and
  //   * a currency/merchant claim can be a LITERAL (`"currency": "SAR"`), which
  //     compares a constant to a constant. A row with only a currency
  //     expectation therefore promoted a rule whose amount capture was wrong —
  //     exactly the SNB card-mask defect, promotable by one row.
  // So when a rule claims `amount`, evidence means a row that pinned the
  // amount. Only a rule that claims no amount at all may qualify on other
  // captured fields.
  const claimsAmount = rule.extracted_fields['amount'] !== undefined;
  const contentChecked = (r: RowResult) =>
    claimsAmount
      ? r.checked_fields.includes('amount')
      : r.checked_fields.some((f) => f !== 'type');
  const meaningful = results.filter((r) =>
    r.applicability !== 'positive' || contentChecked(r)
  );

  const failed = results.filter((r) => !r.passed);
  const falsePositives = results.filter((r) =>
    r.failure_kind === 'false_positive' || r.failure_kind === 'out_of_scope_match'
  ).length;
  const amountErrors = results.filter((r) =>
    r.failure_kind === 'amount_mismatch' || r.failure_kind === 'amount_not_extracted'
  ).length;

  const verifiedPositives = positives.filter((r) =>
    r.passed && contentChecked(r)
  ).length;

  let status: 'passed' | 'failed' = 'passed';
  let reason: string | undefined;
  if (failed.length > 0) {
    status = 'failed';
    reason = `${failed.length} row(s) failed: ${failed[0].failure_kind} on ${failed[0].test_id}`;
  } else if (verifiedPositives < MIN_APPLICABLE_POSITIVES) {
    // THE NON-VACUITY GATE. Without it a rule whose only rows are out-of-scope
    // or expectation-free would pass having proved nothing at all.
    status = 'failed';
    reason =
      `no applicable positive evidence: ${verifiedPositives} verified row(s) of ` +
      `the rule's own class '${rule.transaction_type}', need ${MIN_APPLICABLE_POSITIVES}`;
  }

  return {
    status,
    reason,
    results,
    applicable_positive_count: positives.length,
    applicable_negative_count: negatives.length,
    out_of_scope_count: outOfScope.length,
    golden_test_count: status === 'passed' ? meaningful.length : 0,
    false_positive_count: falsePositives,
    amount_error_count: amountErrors,
  };
}
