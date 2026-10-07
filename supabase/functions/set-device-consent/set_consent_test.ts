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

Deno.test('G1 C.2: v2 set passes client_generation (absent = 0) and returns additive fields', async () => {
  const gen = run({ schema_version: 2, consent_version: 3, client_generation: 4 }, {
    v2Result: { ok: true, applied: false, reason: 'stale_generation', consent_version: 3, consent_client_generation: 6 },
  });
  const r = await gen.res;
  const out = await r.json();
  assertEquals(gen.calls.find((c) => c.fn === 'set_capture_consent')!.args.p_client_generation, 4);
  assertEquals([out.applied, out.reason, out.consent_client_generation], [false, 'stale_generation', 6]);
  const none = run({ schema_version: 2, consent_version: 3 });
  await none.res;
  assertEquals(none.calls.find((c) => c.fn === 'set_capture_consent')!.args.p_client_generation, 0);
});

const REVOKE = { schema_version: 2, action: 'revoke', owner_uid: A, transition_generation: 6, consent_version: 8 };

Deno.test('G1 C.3: v2 action revoke -> revoke_capture_consent AS THE USER, never set_capture_consent', async () => {
  const { calls, res } = run(REVOKE, { v2Result: { ok: true, applied: true, reason: 'revoked' } });
  const r = await res;
  assertEquals([r.status, await r.json()], [200, { ok: true, applied: true, reason: 'revoked' }]);
  const rpc = calls.find((c) => c.fn === 'revoke_capture_consent')!;
  assertEquals(rpc.via, 'user');
  assertEquals(
    { ...rpc.args, p_device_secret_hash: typeof rpc.args.p_device_secret_hash },
    {
      p_install_id_hash: 'h',
      p_device_secret_hash: 'string',
      p_owner_uid: A,
      p_transition_generation: 6,
      p_version: 8,
    },
  );
  assertEquals(calls.some((c) => c.fn === 'set_capture_consent' || c.fn === 'legacy_set_device_consent'), false);
  // its own rate-limit bucket
  assertEquals(
    calls.some((c) => c.fn === 'bump_capture_rate_limit' && String(c.args.p_install_id_hash).endsWith(':revoke-capture-consent')),
    true,
  );
});

Deno.test('G1 C.3: revoke requires the JWT, the device secret and well-formed inputs; no-op results are 200', async () => {
  const noJwt = run(REVOKE, { jwt: false });
  assertEquals((await noJwt.res).status, 401);
  assertEquals(noJwt.calls.some((c) => c.fn === 'revoke_capture_consent'), false);
  assertEquals((await run(REVOKE, { revoked: true }).res).status, 401);
  for (
    const bad of [
      { owner_uid: 'nope' },
      { owner_uid: undefined },
      { transition_generation: -1 },
      { transition_generation: 1.5 },
      { transition_generation: '6' },
      { consent_version: undefined },
    ]
  ) {
    const t = run({ ...REVOKE, ...bad });
    assertEquals((await t.res).status, 400, JSON.stringify(bad));
    assertEquals(t.calls.some((c) => c.fn === 'revoke_capture_consent'), false);
  }
  const noop = await run(REVOKE, { v2Result: { ok: true, applied: false, reason: 'owner_mismatch' } }).res;
  assertEquals([noop.status, (await noop.json()).applied], [200, false]);
  const mm = await run(REVOKE, { v2Result: { ok: false, applied: false, reason: 'owner_mismatch' } }).res;
  assertEquals([mm.status, (await mm.json()).error], [409, 'capture_owner_mismatch']);
  const sec = await run(REVOKE, { v2Result: { ok: false, applied: false, reason: 'invalid_device_secret' } }).res;
  assertEquals(sec.status, 401);
});
