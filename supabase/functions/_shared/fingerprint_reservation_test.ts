import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type FingerprintReservationStore,
  type FingerprintRow,
  reserveCaptureFingerprint,
} from './fingerprint_reservation.ts';

class AtomicMemoryStore implements FingerprintReservationStore {
  private readonly rows = new Map<string, FingerprintRow>();

  async insert(row: {
    install_id_hash: string;
    fingerprint: string;
    payload_id: string;
  }) {
    // Yield both callers before the synchronous unique insert, reproducing the
    // old select-then-insert race while preserving atomic conflict semantics.
    await Promise.resolve();
    const key = `${row.install_id_hash}|${row.fingerprint}`;
    if (this.rows.has(key)) return { error: { code: '23505' } };
    this.rows.set(key, { payload_id: row.payload_id, fingerprint: row.fingerprint });
    return { error: null };
  }

  async find(installIdHash: string, fingerprints: string[]) {
    await Promise.resolve(); // keep the async store-interface signature
    const data = fingerprints
      .map((fingerprint) => this.rows.get(`${installIdHash}|${fingerprint}`))
      .filter((row): row is FingerprintRow => row != null);
    return { data, error: null };
  }

  get size() {
    return this.rows.size;
  }
}

Deno.test('two concurrent payloads reserve one fingerprint and accept one capture', async () => {
  const store = new AtomicMemoryStore();
  const [first, second] = await Promise.all([
    reserveCaptureFingerprint(store, 'install', 'payload-a', ['fingerprint']),
    reserveCaptureFingerprint(store, 'install', 'payload-b', ['fingerprint']),
  ]);
  assertEquals([first, second].filter((result) => result == null).length, 1);
  assertEquals([first, second].filter((result) => result != null).length, 1);
  assertEquals(store.size, 1);
});

Deno.test('same payload replay remains idempotent, not its own duplicate', async () => {
  const store = new AtomicMemoryStore();
  assertEquals(await reserveCaptureFingerprint(store, 'install', 'same', ['fp']), null);
  assertEquals(await reserveCaptureFingerprint(store, 'install', 'same', ['fp']), null);
});

Deno.test('previous bucket remains a read-only duplicate check', async () => {
  const store = new AtomicMemoryStore();
  await reserveCaptureFingerprint(store, 'install', 'old', ['previous']);
  assertEquals(
    await reserveCaptureFingerprint(store, 'install', 'new', ['current', 'previous']),
    'old',
  );
  assertEquals(store.size, 2);
});
