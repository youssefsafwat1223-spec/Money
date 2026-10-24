import { assert, assertEquals, assertNotEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createMaterialSealer, decodeSealerKey } from './material_sealer.ts';

const keyB64 = (fill: number, n = 32) => btoa(String.fromCharCode(...new Uint8Array(n).fill(fill)));
const KEY = keyB64(7);
const TOKEN = 'r.refresh-token-plaintext.value';

Deno.test('seal/unseal round-trips and uses the v1.<iv>.<ct> format with a fresh IV each time', async () => {
  const s = await createMaterialSealer(KEY);
  const a = await s.seal(TOKEN);
  const b = await s.seal(TOKEN);
  assert(/^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/.test(a));
  assertNotEquals(a, b);
  assertEquals(await s.unseal(a), TOKEN);
  assertEquals(await s.unseal(b), TOKEN);
  assert(!a.includes(TOKEN));
});

Deno.test('a tampered IV, ciphertext or tag is refused', async () => {
  const s = await createMaterialSealer(KEY);
  const [v, iv, ct] = (await s.seal(TOKEN)).split('.');
  const flip = (t: string, i: number) => t.slice(0, i) + (t[i] === 'A' ? 'B' : 'A') + t.slice(i + 1);
  await assertRejects(() => s.unseal(`${v}.${flip(iv, 2)}.${ct}`), Error, 'unseal_failed');
  await assertRejects(() => s.unseal(`${v}.${iv}.${flip(ct, 1)}`), Error, 'unseal_failed');
  await assertRejects(() => s.unseal(`${v}.${iv}.${flip(ct, ct.length - 6)}`), Error, 'unseal_failed');
});

Deno.test('a different key cannot unseal', async () => {
  const a = await createMaterialSealer(KEY);
  const b = await createMaterialSealer(keyB64(8));
  const sealed = await a.seal(TOKEN);
  await assertRejects(() => b.unseal(sealed), Error, 'unseal_failed');
});

Deno.test('malformed ciphertexts are refused without echoing input', async () => {
  const s = await createMaterialSealer(KEY);
  const good = await s.seal(TOKEN);
  const [, iv, ct] = good.split('.');
  for (const bad of ['', 'v1', 'v1..', `v2.${iv}.${ct}`, `v1.${iv}`, `v1.${iv}.${ct}.x`, `v1.${iv}.`, `v1.AAAA.${ct}`, 'v1.!!!!.@@@@']) {
    const e = await assertRejects(() => s.unseal(bad));
    assertEquals((e as Error).message, 'unseal_failed');
  }
  await assertRejects(() => s.unseal(undefined as unknown as string), Error, 'unseal_failed');
});

Deno.test('keys that are not base64 of exactly 32 bytes are refused', async () => {
  for (const bad of ['', 'short', keyB64(1, 16), keyB64(1, 31), keyB64(1, 33), keyB64(1, 64), '!'.repeat(44), KEY.slice(0, -1)]) {
    await assertRejects(() => createMaterialSealer(bad), Error, 'sealer_key_invalid');
    assertEquals(decodeSealerKey(bad), null);
  }
  assertEquals(decodeSealerKey(KEY)?.length, 32);
});

Deno.test('sealing an empty value is refused and the key never appears in errors', async () => {
  const s = await createMaterialSealer(KEY);
  await assertRejects(() => s.seal(''), Error, 'seal_input_invalid');
  const bad = keyB64(1, 16);
  const e = await assertRejects(() => createMaterialSealer(bad));
  assert(!(e as Error).message.includes(bad));
});
