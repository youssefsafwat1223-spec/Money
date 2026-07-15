export type FingerprintRow = { payload_id: string; fingerprint: string };

export interface FingerprintReservationStore {
  insert(row: {
    install_id_hash: string;
    fingerprint: string;
    payload_id: string;
  }): Promise<{ error: { code?: string; message?: string } | null }>;
  find(
    installIdHash: string,
    fingerprints: string[],
  ): Promise<{ data: FingerprintRow[] | null; error: { message?: string } | null }>;
}

/**
 * Atomically reserves the current fingerprint and returns the existing payload
 * when the capture is a duplicate. The database unique constraint is the lock.
 */
export async function reserveCaptureFingerprint(
  store: FingerprintReservationStore,
  installIdHash: string,
  payloadId: string,
  fingerprints: string[],
): Promise<string | null> {
  const current = fingerprints[0];
  if (!current) return null;

  const { error: insertError } = await store.insert({
    install_id_hash: installIdHash,
    fingerprint: current,
    payload_id: payloadId,
  });
  if (insertError) {
    if (insertError.code !== '23505') {
      throw new Error(`fingerprint_reservation_failed:${insertError.message ?? insertError.code ?? 'unknown'}`);
    }
    const { data, error } = await store.find(installIdHash, [current]);
    if (error) throw new Error(`fingerprint_lookup_failed:${error.message ?? 'unknown'}`);
    const winner = (data ?? []).find((row) => row.payload_id !== payloadId);
    return winner?.payload_id ?? null;
  }

  // The current key is now ours. Previous buckets are read-only compatibility
  // checks; inserting them would make adjacent legitimate buckets conflict.
  const previous = fingerprints.slice(1);
  if (previous.length === 0) return null;
  const { data, error } = await store.find(installIdHash, previous);
  if (error) throw new Error(`fingerprint_lookup_failed:${error.message ?? 'unknown'}`);
  const hit = (data ?? []).find((row) => row.payload_id !== payloadId);
  return hit?.payload_id ?? null;
}
