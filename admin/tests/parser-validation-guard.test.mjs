import assert from 'node:assert/strict';
import { test } from 'node:test';

/** assert.throws does not return the error, so capture it. */
function caught(fn) {
  try {
    fn();
  } catch (e) {
    return e;
  }
  throw new Error('expected a throw, got none');
}

import {
  EVIDENCE_COLUMNS,
  ParserValidationError,
  guardParserWrite,
  hasEvidence,
  mayServeAsTrusted,
} from '../lib/parser-validation-guard.mjs';

/**
 * F-011 — `validation_status = 'passed'` is an authority, not a description.
 *
 * A passed catalog rule is served to clients as high-confidence and can
 * auto-confirm a parsed transaction as real money (C-1). The admin edit route
 * accepted the status as a plain request field, so one string could promote an
 * unvalidated regex to money-writing authority.
 */

const passedWithEvidence = {
  validation_status: 'passed',
  validated_at: '2026-08-01T00:00:00Z',
  golden_test_count: 12,
};

test('promotion to passed is refused on an edit', () => {
  const err = caught(() => guardParserWrite({ validation_status: 'passed' }, { validation_status: 'pending' }));
  assert.equal(err.code, 'promotion_requires_test_run');
});

test('promotion is refused when creating a rule too', () => {
  // A new rule has no existing row — that must not be a way in.
  const err = caught(() => guardParserWrite({ validation_status: 'passed' }, null));
  assert.equal(err.code, 'promotion_requires_test_run');
});

test('promotion from failed is refused', () => {
  assert.throws(
    () => guardParserWrite({ validation_status: 'passed' }, { validation_status: 'failed' }),
    /golden tests/,
  );
});

test('DEMOTION is always allowed — it removes authority', () => {
  // The asymmetry is deliberate: a mistaken demotion costs a test re-run, a
  // mistaken promotion ships an unvalidated regex that writes confirmed money.
  for (const next of ['pending', 'failed']) {
    const patch = guardParserWrite(
      { validation_status: next },
      passedWithEvidence,
    );
    assert.equal(patch.validation_status, next);
  }
});

test('an unrelated edit to an already-passed rule keeps its status', () => {
  const patch = guardParserWrite(
    { validation_status: 'passed', priority: 50 },
    passedWithEvidence,
  );
  assert.equal(patch.validation_status, 'passed');
  assert.equal(patch.priority, 50);
});

test('a passed row with NO evidence cannot launder its status forward', () => {
  // Rows that reached `passed` before the evidence rule existed must not have
  // that status preserved by an unrelated edit.
  const err = caught(() =>
      guardParserWrite(
        { validation_status: 'passed', priority: 10 },
        { validation_status: 'passed', validated_at: null, golden_test_count: 0 },
      ));
  assert.equal(err.code, 'passed_without_evidence');
});

test('evidence columns are not client-writable', () => {
  // Accepting these would let a caller manufacture the very evidence the
  // promotion rule checks for.
  for (const col of EVIDENCE_COLUMNS) {
    const err = caught(() => guardParserWrite({ [col]: col === 'validated_at' ? 'now' : 99 }, null));
    assert.equal(err.code, 'evidence_not_client_writable', col);
  }
});

test('an unknown status is rejected rather than stored', () => {
  const err = caught(() => guardParserWrite({ validation_status: 'approved' }, null));
  assert.equal(err.code, 'invalid_validation_status');
});

test('edits that do not touch the status pass through untouched', () => {
  const patch = guardParserWrite({ priority: 7, is_active: true }, passedWithEvidence);
  assert.deepEqual(patch, { priority: 7, is_active: true });
});

test('a null status is not treated as a promotion', () => {
  const patch = guardParserWrite({ validation_status: null, priority: 3 }, null);
  assert.equal(patch.priority, 3);
});

test('hasEvidence requires BOTH a timestamp and a non-zero test count', () => {
  assert.equal(hasEvidence(passedWithEvidence), true);
  assert.equal(hasEvidence({ validated_at: '2026-01-01', golden_test_count: 0 }), false);
  assert.equal(hasEvidence({ validated_at: null, golden_test_count: 5 }), false);
  assert.equal(hasEvidence(null), false);
});

test('serving as trusted requires the label AND the evidence', () => {
  // Mirrors the client-side cap: the label alone never buys authority.
  assert.equal(mayServeAsTrusted(passedWithEvidence), true);
  assert.equal(
    mayServeAsTrusted({ validation_status: 'passed', golden_test_count: 0 }),
    false,
  );
  assert.equal(
    mayServeAsTrusted({ ...passedWithEvidence, validation_status: 'pending' }),
    false,
  );
});
