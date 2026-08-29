// Audit H-13 — the operation-id INTENT state machine, extracted as a pure
// module so its behaviour can be tested directly (the React wrapper lives in
// the referrals page).
//
// The server is idempotent per operation_id (referral_admin_claim: same id +
// same fingerprint no-ops; same id + different payload raises
// idempotency_mismatch). The client therefore persists a bounded registry of
// unresolved intents in sessionStorage: a reload can recover an id, while a
// completed intent and a closed tab do not retain it indefinitely.

const PERSISTENCE_VERSION = 1;
export const MAX_PERSISTED_OPERATION_INTENTS = 32;

/**
 * @typedef {{
 *   getItem: (key: string) => string | null,
 *   setItem: (key: string, value: string) => void,
 *   removeItem: (key: string) => void,
 * }} IntentStorage
 * @typedef {{
 *   storage?: IntentStorage | null,
 *   getStorage?: (() => IntentStorage | null) | null,
 *   storageKey?: string | null,
 *   maxEntries?: number,
 * }} OperationIntentOptions
 */

function canonicalValue(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("operation payload numbers must be finite");
    return Object.is(value, -0) ? 0 : value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      const child = value[key];
      if (child === undefined) continue; // Match JSON.stringify's object semantics.
      result[key] = canonicalValue(child);
    }
    return result;
  }
  throw new TypeError(`unsupported operation payload value: ${typeof value}`);
}

/** Stable key for the logical request. The action is always part of the key,
 * and object keys are sorted so construction order cannot change identity. */
export function operationIntentKey(action, payload) {
  if (typeof action !== "string" || action.length === 0) {
    throw new TypeError("operation action must be a non-empty string");
  }
  return JSON.stringify([action, canonicalValue(payload)]);
}

function validEntries(raw, maxEntries) {
  if (!raw || raw.version !== PERSISTENCE_VERSION || !Array.isArray(raw.entries)) return null;
  if (raw.entries.length > maxEntries) return null;

  const keys = new Set();
  const ids = new Map();
  const entries = [];
  for (const entry of raw.entries) {
    if (!entry || typeof entry.id !== "string" || !entry.id || typeof entry.key !== "string" || !entry.key) {
      return null;
    }
    // A corrupted/tampered registry must never cause one id to be returned for
    // two payloads. Reject the whole registry instead of trusting an alias.
    if (keys.has(entry.key) || (ids.has(entry.id) && ids.get(entry.id) !== entry.key)) return null;
    keys.add(entry.key);
    ids.set(entry.id, entry.key);
    entries.push({ id: entry.id, key: entry.key });
  }
  return entries;
}

/**
 * Create an operation-intent tracker.
 *
 * `storage` is a sessionStorage-compatible object. `getStorage` is the lazy
 * form used by React so no browser global is touched during SSR. `mintId` is
 * injected into begin() so tests can make ids deterministic.
 * @param {OperationIntentOptions} [options]
 */
export function createOperationIntent(options = {}) {
  const {
    storage = null,
    getStorage = null,
    storageKey = null,
    maxEntries = MAX_PERSISTED_OPERATION_INTENTS,
  } = options;
  if (!Number.isInteger(maxEntries) || maxEntries < 1) {
    throw new TypeError("maxEntries must be a positive integer");
  }

  let memoryEntries = [];
  let storageUsable = true;

  function persistentStore() {
    if (!storageUsable || !storageKey) return null;
    try {
      return getStorage ? getStorage() : storage;
    } catch {
      storageUsable = false;
      return null;
    }
  }

  function readEntries() {
    const store = persistentStore();
    if (!store) return memoryEntries;
    try {
      const serialized = store.getItem(storageKey);
      if (serialized === null) {
        memoryEntries = [];
        return memoryEntries;
      }
      const entries = validEntries(JSON.parse(serialized), maxEntries);
      if (entries === null) {
        store.removeItem(storageKey);
        memoryEntries = [];
        return memoryEntries;
      }
      memoryEntries = entries;
      return memoryEntries;
    } catch {
      storageUsable = false;
      return memoryEntries;
    }
  }

  function writeEntries(entries) {
    memoryEntries = entries;
    const store = persistentStore();
    if (!store) return;
    try {
      if (entries.length === 0) store.removeItem(storageKey);
      else store.setItem(storageKey, JSON.stringify({ version: PERSISTENCE_VERSION, entries }));
    } catch {
      // sessionStorage may be blocked or full. Preserve rerender stability in
      // memory even though cross-remount recovery is unavailable in that case.
      storageUsable = false;
    }
  }

  return {
    /** Reuse an unresolved exact-payload intent, otherwise mint and persist a
     * new id. The registry is LRU-bounded to avoid unbounded session state. */
    begin(key, mintId) {
      if (typeof key !== "string" || !key) throw new TypeError("intent key must be a non-empty string");
      if (typeof mintId !== "function") throw new TypeError("mintId must be a function");

      const entries = [...readEntries()];
      const existingIndex = entries.findIndex((entry) => entry.key === key);
      if (existingIndex !== -1) {
        const [existing] = entries.splice(existingIndex, 1);
        entries.push(existing);
        writeEntries(entries);
        return existing.id;
      }

      const activeIds = new Set(entries.map((entry) => entry.id));
      let id = null;
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const candidate = mintId();
        if (typeof candidate === "string" && candidate && !activeIds.has(candidate)) {
          id = candidate;
          break;
        }
      }
      if (id === null) throw new Error("could not mint a unique operation_id");

      entries.push({ id, key });
      if (entries.length > maxEntries) entries.splice(0, entries.length - maxEntries);
      writeEntries(entries);
      return id;
    },

    /** Call ONLY on a KNOWN outcome (see outcomeKnown). Matching both key and
     * id prevents an older response from clearing a newer in-flight intent. */
    resolved(key, id) {
      const entries = [...readEntries()];
      const remaining = entries.filter((entry) => entry.key !== key || entry.id !== id);
      if (remaining.length !== entries.length) writeEntries(remaining);
    },

    /** Test/inspection aid. */
    peek(key) {
      const entries = readEntries();
      if (key !== undefined) return entries.find((entry) => entry.key === key) ?? null;
      return entries.at(-1) ?? null;
    },
  };
}

/** True when the server returned a definitive answer (applied OR rejected):
 * a 2xx or 4xx. A transport failure (fetch threw) or a 5xx is an UNKNOWN
 * outcome — the mutation may have committed, so the same id must be resent. */
export function outcomeKnown(r) {
  return !r.transportError && r.status > 0 && r.status < 500;
}
