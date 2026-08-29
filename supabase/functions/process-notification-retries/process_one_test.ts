import { assertEquals } from 'jsr:@std/assert@1';
import { processOne } from './process_one.ts';

const row = {
  id: 'retry-1',
  notification_log_id: 'log-1',
  install_id_hash: 'install-hash',
  payload_id: 'payload-1',
  attempt_number: 1,
  max_attempts: 5,
};

const capture = {
  data: {
    notification: {
      title: 'New transaction',
      body: 'A transaction needs review',
      type: 'needs_review',
    },
    apns_push_sent_at: null,
  },
  error: null,
};

type RecordedUpdate = {
  table: string;
  values: Record<string, unknown>;
  filters: Array<[string, unknown]>;
};

// deno-lint-ignore no-explicit-any
function fakeSupabase(device: Record<string, unknown>): { client: any; updates: RecordedUpdate[] } {
  const updates: RecordedUpdate[] = [];
  const client = {
    from(table: string) {
      let updateValues: Record<string, unknown> | null = null;
      const filters: Array<[string, unknown]> = [];
      let recorded = false;
      const builder = {
        select() {
          return builder;
        },
        update(values: Record<string, unknown>) {
          updateValues = values;
          return builder;
        },
        eq(column: string, value: unknown) {
          filters.push([column, value]);
          return builder;
        },
        maybeSingle() {
          if (table === 'processed_captures') return Promise.resolve(capture);
          if (table === 'capture_devices') {
            return Promise.resolve({ data: device, error: null });
          }
          return Promise.resolve({ data: null, error: null });
        },
        then(resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) {
          if (updateValues != null && !recorded) {
            updates.push({ table, values: updateValues, filters: [...filters] });
            recorded = true;
          }
          return Promise.resolve({ data: null, error: null }).then(resolve, reject);
        },
      };
      return builder;
    },
  };
  return { client, updates };
}

Deno.test('revoked device retry is dropped without sending to APNs', async () => {
  const fake = fakeSupabase({
    apns_token: 'still-stored-token',
    apns_environment: 'sandbox',
    revoked_at: '2026-08-25T00:00:00Z',
  });
  let sendCalls = 0;

  const outcome = await processOne(fake.client, row, () => {
    sendCalls++;
    return Promise.resolve({ ok: true, apnsId: 'must-not-send' } as const);
  });

  assertEquals(outcome, 'exhausted');
  assertEquals(sendCalls, 0);
  assertEquals(
    fake.updates.some((update) =>
      update.table === 'notification_retry_queue' && typeof update.values.resolved_at === 'string'
    ),
    true,
  );
  assertEquals(
    fake.updates.some((update) =>
      update.table === 'notification_logs' && update.values.error_code === 'credential_revoked'
    ),
    true,
  );
});

Deno.test('non-revoked device retry preserves normal APNs delivery', async () => {
  const fake = fakeSupabase({
    apns_token: 'active-token',
    apns_environment: 'production',
    revoked_at: null,
  });
  const sentTokens: string[] = [];

  const outcome = await processOne(fake.client, row, (message) => {
    sentTokens.push(message.token);
    return Promise.resolve({ ok: true, apnsId: 'apns-1' } as const);
  });

  assertEquals(outcome, 'sent');
  assertEquals(sentTokens, ['active-token']);
  assertEquals(
    fake.updates.some((update) =>
      update.table === 'processed_captures' && typeof update.values.apns_push_sent_at === 'string'
    ),
    true,
  );
  assertEquals(
    fake.updates.some((update) =>
      update.table === 'notification_retry_queue' && typeof update.values.resolved_at === 'string'
    ),
    true,
  );
});
