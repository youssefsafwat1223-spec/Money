import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { captureProcessingConsent, handleProcessIosSms } from './index.ts';

const CID = 'consent-test-cid';

function decision(
  data: {
    ai_consent_granted?: unknown;
    cloud_processing_enabled?: unknown;
    revoked_at?: unknown;
  } | null,
  error: unknown = null,
  allowAi = true,
) {
  return captureProcessingConsent({ data, error }, allowAi, CID);
}

async function errorCode(response: Response): Promise<string> {
  return (await response.json()).error as string;
}

Deno.test('cloud OFF is a typed process-ios-sms refusal', async () => {
  const out = decision({
    cloud_processing_enabled: false,
    ai_consent_granted: true,
    revoked_at: null,
  });
  assertEquals(out.ok, false);
  if (!out.ok) {
    assertEquals(out.response.status, 403);
    assertEquals(await errorCode(out.response), 'consent_required');
  }
});

Deno.test('revoked device is refused even when both consent flags remain true', async () => {
  const out = decision({
    cloud_processing_enabled: true,
    ai_consent_granted: true,
    revoked_at: '2026-08-25T00:00:00Z',
  });
  assertEquals(out.ok, false);
  if (!out.ok) {
    assertEquals(out.response.status, 401);
    assertEquals(await errorCode(out.response), 'credential_revoked');
  }
});

Deno.test('missing or errored consent row fails closed', async () => {
  for (const out of [decision(null), decision(null, { message: 'lookup failed' })]) {
    assertEquals(out.ok, false);
    if (!out.ok) {
      assertEquals(out.response.status, 403);
      assertEquals(await errorCode(out.response), 'consent_required');
    }
  }
});

Deno.test('AI requires cloud enabled, AI consent, and caller request', () => {
  const aiOff = decision({
    cloud_processing_enabled: true,
    ai_consent_granted: false,
    revoked_at: null,
  });
  assertEquals(aiOff, { ok: true, aiAllowed: false });

  const notRequested = decision(
    {
      cloud_processing_enabled: true,
      ai_consent_granted: true,
      revoked_at: null,
    },
    null,
    false,
  );
  assertEquals(notRequested, { ok: true, aiAllowed: false });

  const allowed = decision({
    cloud_processing_enabled: true,
    ai_consent_granted: true,
    revoked_at: null,
  });
  assertEquals(allowed, { ok: true, aiAllowed: true });
});

function validRequest(): Request {
  return new Request('https://example.test/process-ios-sms', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      schema_version: 1,
      installId: 'install-1',
      deviceSecret: 'secret-1',
      payloadId: 'already-seen-payload',
      sanitizedText: 'Paid EGP 19.99',
      allowAi: true,
    }),
  });
}

function refusalClient(consentResult: {
  data: Record<string, unknown> | null;
  error: unknown;
}) {
  const tables: string[] = [];
  const selections: string[] = [];
  const builder: Record<string, unknown> = {};
  builder.select = (columns: string) => {
    selections.push(columns);
    return builder;
  };
  builder.eq = () => builder;
  builder.maybeSingle = () => Promise.resolve(consentResult);
  return {
    tables,
    selections,
    client: {
      from(table: string) {
        tables.push(table);
        return builder;
      },
    },
  };
}

Deno.test('stale replay after revocation stops before parse, storage, ledger, or APNs', async () => {
  const fake = refusalClient({
    data: {
      cloud_processing_enabled: true,
      ai_consent_granted: true,
      revoked_at: '2026-08-25T00:00:00Z',
    },
    error: null,
  });
  let fetchCalls = 0;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error('network/APNs/AI must not run');
  }) as typeof fetch;
  try {
    const response = await handleProcessIosSms(validRequest(), {
      createServiceClient: (() => fake.client) as never,
      verifyDevice: (() =>
        Promise.resolve({
          ok: true,
          installIdHash: 'verified-install-hash',
          userId: 'user-1',
        })) as never,
    });
    assertEquals(response.status, 401);
    assertEquals(await errorCode(response), 'credential_revoked');
  } finally {
    globalThis.fetch = originalFetch;
  }
  assertEquals(fake.tables, ['capture_devices']);
  assertEquals(fake.selections, [
    'ai_consent_granted, cloud_processing_enabled, revoked_at',
  ]);
  assertEquals(fetchCalls, 0);
});

Deno.test('cloud OFF stops before processed_captures and APNs', async () => {
  const fake = refusalClient({
    data: {
      cloud_processing_enabled: false,
      ai_consent_granted: true,
      revoked_at: null,
    },
    error: null,
  });
  const response = await handleProcessIosSms(validRequest(), {
    createServiceClient: (() => fake.client) as never,
    verifyDevice: (() =>
      Promise.resolve({
        ok: true,
        installIdHash: 'verified-install-hash',
        userId: null,
      })) as never,
  });
  assertEquals(response.status, 403);
  assertEquals(await errorCode(response), 'consent_required');
  assertEquals(fake.tables, ['capture_devices']);
});
