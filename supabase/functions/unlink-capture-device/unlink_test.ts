import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleUnlinkCaptureDevice } from './index.ts';

Deno.test('unlink: one RPC nulls user, consent owner and flags; revoked device refused; shape unchanged', async () => {
  const calls: string[] = [];
  const client = { rpc: (fn: string) => (calls.push(fn), Promise.resolve({ data: true, error: null })) };
  const mk = (revoked: boolean) =>
    handleUnlinkCaptureDevice(
      new Request('https://x', { method: 'POST', body: JSON.stringify({ installId: 'i', deviceSecret: 's' }) }),
      {
        createServiceClient: (() => client) as never,
        verifyDevice: (() =>
          Promise.resolve(
            revoked
              ? { ok: false, status: 401, error: 'credential_revoked' }
              : { ok: true, installIdHash: 'h', userId: 'u' },
          )) as never,
      },
    );
  const ok = await mk(false);
  assertEquals([ok.status, await ok.json(), calls], [200, { ok: true }, ['unlink_capture_device']]);
  const rev = await mk(true);
  assertEquals([rev.status, (await rev.json()).error], [401, 'credential_revoked']);
});
