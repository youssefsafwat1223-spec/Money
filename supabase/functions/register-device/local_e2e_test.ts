// LOCAL END-TO-END for register-device.
//
// `handler_test.ts` drives the exported handler against a fake PostgREST
// builder. This is a level closer to production: it runs the REAL `Deno.serve`
// entry point over real HTTP, with `serviceClient()` pointed at a stub
// PostgREST, and asserts on the BODY that actually goes on the wire.
//
// It exists because the defect was a column the upsert did not send. A fake
// query builder can model that; only a real request proves what the Supabase
// client actually serialises. `supabase functions serve` would be closer still,
// but it needs Docker, which is not available here — this is the nearest
// equivalent that does not require it.
import { assert, assertEquals } from 'jsr:@std/assert@1';

const PORT = 877;
const stubRequests: Array<{ method: string; path: string; body: unknown }> = [];

// The stub PostgREST. `capture_devices` rows live here; the handler's rate
// limiter calls an RPC first, which we answer "not limited".
let existingRow: Record<string, unknown> | null = null;

const server = Deno.serve({ port: PORT, onListen: () => {} }, async (req) => {
  const url = new URL(req.url);
  const bodyText = req.method === 'POST' || req.method === 'PATCH'
    ? await req.text()
    : '';
  const body = bodyText ? JSON.parse(bodyText) : null;
  stubRequests.push({ method: req.method, path: url.pathname, body });

  if (url.pathname.endsWith('/rpc/bump_capture_rate_limit')) {
    return new Response('false', {
      headers: { 'content-type': 'application/json' },
    });
  }
  if (url.pathname.endsWith('/capture_devices')) {
    if (req.method === 'GET') {
      return new Response(JSON.stringify(existingRow ? [existingRow] : []), {
        headers: { 'content-type': 'application/json' },
      });
    }
    // The upsert.
    const rows = Array.isArray(body) ? body : [body];
    for (const row of rows) {
      existingRow = { ...(existingRow ?? {}), ...row };
    }
    return new Response('[]', {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  }
  return new Response('[]', { headers: { 'content-type': 'application/json' } });
});

Deno.env.set('SUPABASE_URL', `http://127.0.0.1:${PORT}`);
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'stub-service-role');
Deno.env.set('SUPABASE_ANON_KEY', 'stub-anon');

const { handleRegisterDevice } = await import('./index.ts');

function post(body: unknown): Request {
  return new Request('http://localhost/functions/v1/register-device', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/// The upsert body the handler actually put on the wire.
function lastUpsertBody(): Record<string, unknown> {
  const upserts = stubRequests.filter((r) =>
    r.path.endsWith('/capture_devices') && r.method === 'POST'
  );
  assert(upserts.length > 0, 'the handler made no upsert at all');
  const body = upserts[upserts.length - 1].body;
  return (Array.isArray(body) ? body[0] : body) as Record<string, unknown>;
}

Deno.test('the wire body clears user_id when rotating a linked install', async () => {
  stubRequests.length = 0;
  // A device already linked to a victim, exactly as link-capture-device leaves it.
  existingRow = {
    install_id_hash: 'placeholder',
    user_id: 'victim-user',
    created_at: '2026-01-01T00:00:00.000Z',
    device_secret_hash: 'old-hash',
  };

  const res = await handleRegisterDevice(post({ installId: 'victim-install' }));
  assertEquals(res.status, 200);
  const payload = await res.json() as Record<string, unknown>;
  assertEquals((payload.deviceSecret as string).length, 64);

  const sent = lastUpsertBody();
  // THE ASSERTION. Before the fix this key was absent, so PostgREST's
  // ON CONFLICT left the victim's link intact and sync-captures served their
  // rows to whoever rotated.
  assert(
    'user_id' in sent,
    'the upsert omitted user_id entirely — that is the defect: ON CONFLICT leaves the existing link in place',
  );
  assertEquals(sent.user_id, null);
  // revoked_at must NOT be sent: rotation is a device-owner action and must not
  // clear an operator's revocation.
  assert(!('revoked_at' in sent), 'rotation must not touch revoked_at');
  // created_at is preserved from the existing row, not reset.
  assertEquals(sent.created_at, '2026-01-01T00:00:00.000Z');
});

Deno.test('a first registration sends an unlinked row', async () => {
  stubRequests.length = 0;
  existingRow = null;
  const res = await handleRegisterDevice(
    post({ installId: 'fresh-install', platform: 'android' }),
  );
  assertEquals(res.status, 200);
  const sent = lastUpsertBody();
  assertEquals(sent.user_id, null);
  assertEquals(sent.platform, 'android');
});

Deno.test('a missing installId never reaches the database', async () => {
  stubRequests.length = 0;
  const res = await handleRegisterDevice(post({}));
  assertEquals(res.status, 400);
  assertEquals(stubRequests.length, 0);
});

Deno.test('teardown', async () => {
  await server.shutdown();
});
