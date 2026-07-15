import assert from 'node:assert/strict';
import test from 'node:test';

import { reserveCaptureFingerprint } from '../functions/_shared/fingerprint_reservation.ts';

class AtomicMemoryStore {
  rows = new Map();

  async insert(row) {
    await Promise.resolve();
    const key = `${row.install_id_hash}|${row.fingerprint}`;
    if (this.rows.has(key)) return { error: { code: '23505' } };
    this.rows.set(key, {
      payload_id: row.payload_id,
      fingerprint: row.fingerprint,
    });
    return { error: null };
  }

  async find(installIdHash, fingerprints) {
    return {
      data: fingerprints
        .map((fingerprint) => this.rows.get(`${installIdHash}|${fingerprint}`))
        .filter(Boolean),
      error: null,
    };
  }
}

test('concurrent duplicate reservation accepts exactly one payload', async () => {
  const store = new AtomicMemoryStore();
  const results = await Promise.all([
    reserveCaptureFingerprint(store, 'install', 'payload-a', ['fingerprint']),
    reserveCaptureFingerprint(store, 'install', 'payload-b', ['fingerprint']),
  ]);

  assert.equal(results.filter((result) => result == null).length, 1);
  assert.equal(results.filter((result) => result != null).length, 1);
  assert.equal(store.rows.size, 1);
});

test('same payload replay keeps payloadId idempotency unchanged', async () => {
  const store = new AtomicMemoryStore();
  assert.equal(
    await reserveCaptureFingerprint(store, 'install', 'same', ['fingerprint']),
    null,
  );
  assert.equal(
    await reserveCaptureFingerprint(store, 'install', 'same', ['fingerprint']),
    null,
  );
  assert.equal(store.rows.size, 1);
});
