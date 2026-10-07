import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleLinkCaptureDevice } from './index.ts';

const A = '00000000-0000-0000-0000-00000000a001';

function run(body: Record<string, unknown>, opts: { revoked?: boolean; jwt?: boolean; legacyOk?: boolean } = {}) {
  const calls: Array<{ via: string; fn: string; args: Record<string, unknown> }> = [];
  const service = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ via: 'service', fn, args });
      if (fn === 'bump_capture_rate_limit') return Promise.resolve({ data: false, error: null });
      return Promise.resolve({ data: opts.legacyOk ?? true, error: null });
    },
  };
  const userClient = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ via: 'user', fn, args });
      return Promise.resolve({ data: { ok: true, owner_changed: true }, error: null });
    },
  };
  const res = handleLinkCaptureDevice(
    new Request('https://x/link', {
      method: 'POST',
      body: JSON.stringify({ installId: 'i', deviceSecret: 's', ...body }),
    }),
    {
      createServiceClient: (() => service) as never,
      verifyDevice: (() =>
        Promise.resolve(
          opts.revoked
            ? { ok: false, status: 401, error: 'credential_revoked' }
            : { ok: true, installIdHash: 'h', userId: null },
        )) as never,
      verifyUserJwt: (() =>
        Promise.resolve(
          opts.jwt === false
            ? { ok: false, status: 401, error: 'missing_jwt' }
            : { ok: true, userId: A, client: userClient },
        )) as never,
    },
  );
  return { calls, res };
}

Deno.test('legacy link: one atomic RPC (owner change resets consent in SQL), response {ok:true} unchanged', async () => {
  const { calls, res } = run({});
  const r = await res;
  assertEquals([r.status, await r.json()], [200, { ok: true }]);
  const link = calls.find((c) => c.fn === 'legacy_link_capture_device')!;
  assertEquals(link.args, { p_install_id_hash: 'h', p_user_id: A });
  assertEquals(calls.some((c) => c.via === 'user'), false);
});

Deno.test('legacy link refuses a revoked device and requires the JWT', async () => {
  const rev = await run({}, { revoked: true }).res;
  assertEquals([rev.status, (await rev.json()).error], [401, 'credential_revoked']);
  const nojwt = await run({}, { jwt: false }).res;
  assertEquals([nojwt.status, (await nojwt.json()).error], [401, 'missing_jwt']);
  const gone = await run({}, { legacyOk: false }).res;
  assertEquals(gone.status, 401);
});

Deno.test('v2 link: link_capture_device RPC runs as the USER with consent, never via the service client', async () => {
  const { calls, res } = run({
    schema_version: 2,
    consent: { cloud_processing_enabled: true, ai_consent_granted: false, version: 4 },
  });
  const r = await res;
  assertEquals([r.status, await r.json()], [200, { ok: true, owner_changed: true }]);
  const link = calls.find((c) => c.fn === 'link_capture_device')!;
  assertEquals(link.via, 'user');
  assertEquals(
    { ...link.args, p_device_secret_hash: typeof link.args.p_device_secret_hash },
    { p_install_id_hash: 'h', p_device_secret_hash: 'string', p_cloud: true, p_ai: false, p_version: 4 },
  );
  assertEquals(calls.some((c) => c.fn === 'legacy_link_capture_device'), false);
});

Deno.test('v2 link: missing or invalid consent version -> 400', async () => {
  for (const consent of [undefined, {}, { version: -1 }, { version: 'x' }]) {
    const r = await run({ schema_version: 2, consent }).res;
    assertEquals(r.status, 400);
  }
});
