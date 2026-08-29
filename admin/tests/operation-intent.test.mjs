// Cross-model audit H-13 — Admin operation idempotency (Batch 14 / R8).
//
// These are behavioural tests of the extracted state machine. A fresh machine
// over the same in-memory sessionStorage shim represents a page reload/remount.
import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_PERSISTED_OPERATION_INTENTS,
  createOperationIntent,
  operationIntentKey,
  outcomeKnown,
} from "../lib/operation-intent.mjs";

const STORAGE_KEY = "test.operation-intents";

function counter() {
  let n = 0;
  return () => `op-${++n}`;
}

function memorySessionStorage() {
  const items = new Map();
  return {
    getItem(key) {
      return items.has(key) ? items.get(key) : null;
    },
    setItem(key, value) {
      items.set(key, String(value));
    },
    removeItem(key) {
      items.delete(key);
    },
  };
}

function persistedIntent(storage, options = {}) {
  return createOperationIntent({ storage, storageKey: STORAGE_KEY, ...options });
}

// Simulate one submit: begin an intent, "send", classify the outcome, and (on
// a KNOWN outcome) resolve. Returns the operation_id the server received.
function submit(intent, mint, key, outcome) {
  const operationId = intent.begin(key, mint);
  if (outcomeKnown(outcome)) intent.resolved(key, operationId);
  return operationId;
}

const OK = { status: 200, transportError: false };
const REJECTED = { status: 400, transportError: false };
const LOST = { status: 0, transportError: true };
const GATEWAY = { status: 502, transportError: false };

const ACTION_CASES = [
  [
    "grant",
    { reason: "compensation", user_id: "user-1", action: "grant", duration_days: 7 },
    { reason: "compensation", user_id: "user-1", action: "grant", duration_days: 8 },
  ],
  [
    "extend",
    { reason: "support", user_id: "user-1", action: "extend", duration_days: 7 },
    { reason: "support", user_id: "user-2", action: "extend", duration_days: 7 },
  ],
  [
    "shorten",
    { reason: "correction", user_id: "user-1", action: "shorten", duration_days: 2 },
    { reason: "correction", user_id: "user-1", action: "shorten", duration_days: 3 },
  ],
  [
    "revoke",
    { reason: "requested", user_id: "user-1", action: "revoke" },
    { reason: "requested", user_id: "user-2", action: "revoke" },
  ],
  [
    "adjust_progress",
    {
      reason: "repair",
      referrer_user_id: "user-1",
      reward_type: "report_export_ad_free",
      qualified_in_cycle: 3,
    },
    {
      reason: "repair",
      referrer_user_id: "user-1",
      reward_type: "report_export_ad_free",
      qualified_in_cycle: 4,
    },
  ],
  [
    "rotate_code",
    { reason: "code exposed", user_id: "user-1" },
    { reason: "confirmed abuse", user_id: "user-1" },
  ],
  [
    "reject",
    { referral_id: "referral-1", reason: "ineligible" },
    { referral_id: "referral-2", reason: "ineligible" },
  ],
  [
    "reverse",
    { referral_id: "referral-1", reason: "fraud" },
    { referral_id: "referral-1", reason: "duplicate account" },
  ],
  [
    "publish",
    {
      reward_type: "report_export_ad_free",
      required_referrals: 5,
      reward_days: 7,
      repeatable: true,
      reason: "new campaign",
    },
    {
      reward_type: "report_export_ad_free",
      required_referrals: 6,
      reward_days: 7,
      repeatable: true,
      reason: "new campaign",
    },
  ],
  [
    "deactivate",
    { reward_type: "report_export_ad_free", reason: "campaign ended" },
    { reward_type: "report_export_ad_free", reason: "fraud pause" },
  ],
];

test("outcomeKnown: only server responses below 500 are definitive", () => {
  assert.equal(outcomeKnown(OK), true);
  assert.equal(outcomeKnown(REJECTED), true);
  assert.equal(outcomeKnown(LOST), false, "a transport failure is unknown");
  assert.equal(outcomeKnown(GATEWAY), false, "a 5xx is unknown");
});

test("committed-but-lost response -> reload -> same logical intent reuses operation_id", () => {
  const storage = memorySessionStorage();
  const mint = counter();
  const key = operationIntentKey("grant", {
    reason: "compensation",
    user_id: "user-1",
    action: "grant",
    duration_days: 7,
  });

  const beforeReload = submit(persistedIntent(storage), mint, key, LOST);
  const afterReload = submit(persistedIntent(storage), mint, key, OK);

  assert.equal(
    afterReload,
    beforeReload,
    "a fresh machine must recover the id; the pre-R8 in-memory machine minted op-2 here",
  );
});

test("all 10 admin actions survive remount for the same payload and split different payloads", () => {
  for (const [action, payload, changedPayload] of ACTION_CASES) {
    const storage = memorySessionStorage();
    const mint = counter();
    const key = operationIntentKey(action, payload);
    const changedKey = operationIntentKey(action, changedPayload);

    // The server committed the first attempt, but its response was lost.
    const first = submit(persistedIntent(storage), mint, key, LOST);
    // A page reload creates a fresh machine over the same tab-scoped store.
    const retryAfterReload = submit(persistedIntent(storage), mint, key, LOST);
    assert.equal(retryAfterReload, first, `${action}: same payload must recover the persisted id`);

    const changedAfterReload = submit(persistedIntent(storage), mint, changedKey, LOST);
    assert.notEqual(changedAfterReload, first, `${action}: changed payload must mint a new id`);

    // Receiving a definitive duplicate-success for the original clears only
    // that exact intent, leaving the changed unresolved intent intact.
    assert.equal(submit(persistedIntent(storage), mint, key, OK), first, `${action}: retry must stay idempotent`);
    assert.equal(
      persistedIntent(storage).peek(changedKey)?.id,
      changedAfterReload,
      `${action}: resolving one payload must not clear another`,
    );
  }
});

test("same operation_id is never emitted for two different payloads", () => {
  const storage = memorySessionStorage();
  const keyA = operationIntentKey("reject", { referral_id: "ref-1", reason: "fraud" });
  const keyB = operationIntentKey("reject", { referral_id: "ref-2", reason: "fraud" });
  const idA = persistedIntent(storage).begin(keyA, () => "collision");

  const candidates = ["collision", "different-id"];
  const idB = persistedIntent(storage).begin(keyB, () => candidates.shift());
  assert.equal(idA, "collision");
  assert.equal(idB, "different-id", "an active id collision must be discarded and re-minted");
  assert.notEqual(idA, idB);
});

test("known definitive completion clears persistence and a later same payload gets a fresh id", () => {
  for (const definitive of [OK, REJECTED]) {
    const storage = memorySessionStorage();
    const mint = counter();
    const key = operationIntentKey("extend", {
      reason: "support",
      user_id: "user-1",
      action: "extend",
      duration_days: 7,
    });

    const completed = submit(persistedIntent(storage), mint, key, definitive);
    assert.equal(persistedIntent(storage).peek(key), null, "known outcome must remove the stored record");
    const laterNewIntent = persistedIntent(storage).begin(key, mint);
    assert.notEqual(laterNewIntent, completed, "a deliberate later action must start fresh");
  }
});

test("transport-unknown and 5xx outcomes do not clear persistence", () => {
  for (const unknown of [LOST, GATEWAY]) {
    const storage = memorySessionStorage();
    const mint = counter();
    const key = operationIntentKey("rotate_code", { reason: "exposed", user_id: "user-1" });
    const first = submit(persistedIntent(storage), mint, key, unknown);
    assert.equal(persistedIntent(storage).peek(key)?.id, first, "unknown outcome must remain stored");
    assert.equal(persistedIntent(storage).begin(key, mint), first, "retry after reload must reuse it");
  }
});

test("canonical payload key reflects sent values, not object order or raw numeric UI formatting", () => {
  const fromUiA = operationIntentKey("publish", {
    reward_days: Number("07"),
    required_referrals: Number("5"),
    reason: "campaign",
  });
  const fromUiB = operationIntentKey("publish", {
    reason: "campaign",
    required_referrals: 5,
    reward_days: 7,
  });
  assert.equal(fromUiA, fromUiB);
});

test("same unresolved intent remains stable across ordinary rerenders", () => {
  const intent = createOperationIntent();
  const mint = counter();
  const key = operationIntentKey("reverse", { referral_id: "ref-1", reason: "fraud" });
  assert.equal(intent.begin(key, mint), intent.begin(key, mint));
});

test("persistent registry is bounded", () => {
  const storage = memorySessionStorage();
  const mint = counter();
  const intent = persistedIntent(storage);
  for (let i = 0; i < MAX_PERSISTED_OPERATION_INTENTS + 5; i += 1) {
    intent.begin(operationIntentKey("grant", { user_id: `user-${i}` }), mint);
  }
  const persisted = JSON.parse(storage.getItem(STORAGE_KEY));
  assert.equal(persisted.entries.length, MAX_PERSISTED_OPERATION_INTENTS);
  assert.equal(
    persisted.entries[0].key,
    operationIntentKey("grant", { user_id: "user-5" }),
    "the oldest unresolved entries are evicted first",
  );
});
