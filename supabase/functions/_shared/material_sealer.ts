// AES-256-GCM sealer for the temporary Apple refresh token (decision D4).
// Format: v1.<base64url(iv)>.<base64url(ciphertext||tag)>, 12-byte random IV.
// The key is supplied as base64 of exactly 32 bytes (ACCOUNT_DELETION_SEALER_KEY)
// and is never logged. Every failure throws a fixed, content-free message.

import type { MaterialSealer } from './account_deletion_adapter.ts';

const IV_BYTES = 12;
const KEY_BYTES = 32;
const B64URL_RE = /^[A-Za-z0-9_-]+$/;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

export function b64urlEncode(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

export function b64urlDecode(text: string): Uint8Array {
  if (!B64URL_RE.test(text) || text.length % 4 === 1) throw new Error('base64url_invalid');
  const padded = text.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - (text.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Decodes the key; returns null unless it is canonical-looking base64 of exactly 32 bytes. */
export function decodeSealerKey(keyBase64: unknown): Uint8Array | null {
  if (typeof keyBase64 !== 'string') return null;
  const t = keyBase64.trim();
  if (t.length === 0 || t.length % 4 !== 0 || !B64_RE.test(t)) return null;
  try {
    const bin = atob(t);
    if (bin.length !== KEY_BYTES) return null;
    const out = new Uint8Array(KEY_BYTES);
    for (let i = 0; i < KEY_BYTES; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** Throws 'sealer_key_invalid' on a wrong-length or malformed key. */
export async function createMaterialSealer(
  keyBase64: string,
  randomBytes: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n)),
): Promise<MaterialSealer> {
  const raw = decodeSealerKey(keyBase64);
  if (!raw) throw new Error('sealer_key_invalid');
  const key = await crypto.subtle.importKey('raw', raw as BufferSource, 'AES-GCM', false, ['encrypt', 'decrypt']);
  raw.fill(0);

  return {
    async seal(plaintext: string): Promise<string> {
      if (typeof plaintext !== 'string' || plaintext.length === 0) throw new Error('seal_input_invalid');
      const iv = randomBytes(IV_BYTES);
      if (iv.length !== IV_BYTES) throw new Error('seal_failed');
      const ct = new Uint8Array(
        await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv as BufferSource }, key, new TextEncoder().encode(plaintext)),
      );
      return `v1.${b64urlEncode(iv)}.${b64urlEncode(ct)}`;
    },
    async unseal(ciphertext: string): Promise<string> {
      try {
        if (typeof ciphertext !== 'string') throw new Error();
        const parts = ciphertext.split('.');
        if (parts.length !== 3 || parts[0] !== 'v1') throw new Error();
        const iv = b64urlDecode(parts[1]);
        const ct = b64urlDecode(parts[2]);
        if (iv.length !== IV_BYTES || ct.length < 17) throw new Error();
        const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv as BufferSource }, key, ct as BufferSource);
        return new TextDecoder('utf-8', { fatal: true }).decode(pt);
      } catch {
        throw new Error('unseal_failed');
      }
    },
  };
}
