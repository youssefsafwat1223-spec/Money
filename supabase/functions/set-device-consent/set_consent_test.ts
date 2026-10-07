import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleSetDeviceConsent } from './index.ts';

const A = '00000000-0000-0000-0000-00000000a001';

function run(
  body: Record<string, unknown>,
  opts: {
    legacyResult?: Record<string, unknown>;
    v2Result?: Record<string, unknown>;
    jwt?: boolean;
    revoked?: boolean;
  } = {},
) {
  const calls: Array<{ via: string; fn: string; args: Record<string, unknown> }> = [];
  const service = {
    from: () => ({ update: () => ({ eq: () => Promise.resolve({}) }) }),
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ via: 'service', fn, args });
      if (fn === 'bump_capture_rate_limit') return Promise.resolve({ data: false, error: null });
      return Promise.resolve({ data: opts.legacyResult ?? { ok: true }, error: null });
    },
  };
  const userClient = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ via: 'user', fn, args });
      return Promise.resolve({ data: opts.v2Result ?? { ok: true, applied: true }, error: null });
    },
  };
  const res = handleSetDeviceConsent(
    new Request('https://x/consent', {
      method: 'POST',
      body: JSON.stringify({ installId: 'i', deviceSecret: 's', ...body }),
    }),
    {
      createServiceClient: (() => service) as never,
      resolveVerifiedIdentity: (() =>
        Promise.resolve({
          ok: true,
          identity: {
            kind: 'device',
            ownerKey: 'd:h',
            userId: null,
            installIdHash: 'h',
            aiConsent: false,
            cloudConsent: false,
          },
        })) as never,
      verifyDevice: (() =>
        Promise.resolve(
          opts.revoked
            ? { ok: false, status: 401, error: 'credential_revoked' }
            : { ok: true, installIdHash: 'h', userId: A },
        )) as never,
      verifyUserJwt: (() =>
        Promise.resolve(
          opts.jwt === false ? { ok: false, status: 401, error: 'x' } : { ok: true, userId: A, client: userClient },
        )) as never,
    },
  );
  return { calls, res };
}

Deno.test('legacy: device-credential write goes through the owner-scoped RPC, response shape unchanged', async () => {
  const { calls, res } = run({ ai_consent_granted: true, cloud_processing_enabled: true });
  const r = await res;
  assertEquals([r.status, await r.json()], [200, {
    ok: true,
    ai_consent_granted: true,
    cloud_processing_enabled: true,
  }]);
  const rpc = calls.find((c) => c.fn === 'legacy_set_device_consent')!;
  assertEquals([rpc.via, rpc.args], ['service', { p_install_id_hash: 'h', p_cloud: true, p_ai: true }]);
});

Deno.test('legacy: consent not owned by the linked user is refused (409), nothing reported as written', async () => {
  const r = await run({ ai_consent_granted: true }, { legacyResult: { ok: false, error: 'capture_owner_mismatch' } })
    .res;
  assertEquals([r.status, (await r.json()).error], [409, 'capture_owner_mismatch']);
});

Deno.test('v2: requires JWT; set_capture_consent runs AS THE USER with a version', async () => {
  const noJwt = await run({ schema_version: 2, consent_version: 3 }, { jwt: false }).res;
  assertEquals(noJwt.status, 401);
  const { calls, res } = run({
    schema_version: 2,
    consent_version: 3,
    ai_consent_granted: false,
    cloud_processing_enabled: true,
  });
  const r = await res;
  assertEquals([r.status, (await r.json()).applied], [200, true]);
  const rpc = calls.find((c) => c.fn === 'set_capture_consent')!;
  assertEquals(rpc.via, 'user');
  assertEquals([rpc.args.p_cloud, rpc.args.p_ai, rpc.args.p_version], [true, false, 3]);
  assertEquals(calls.some((c) => c.fn === 'legacy_set_device_consent'), false);
});

Deno.test('v2: owner mismatch -> 409; revoked device -> 401; missing version -> 400', async () => {
  const mm = await run({ schema_version: 2, consent_version: 3 }, {
    v2Result: { ok: false, error: 'capture_owner_mismatch' },
  }).res;
  assertEquals([mm.status, (await mm.json()).error], [409, 'capture_owner_mismatch']);
  const rev = await run({ schema_version: 2, consent_version: 3 }, { revoked: true }).res;
  assertEquals(rev.status, 401);
  const nov = await run({ schema_version: 2 }).res;
  assertEquals(nov.status, 400);
});
