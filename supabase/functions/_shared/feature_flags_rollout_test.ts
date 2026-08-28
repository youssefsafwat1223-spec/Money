// C-10 — the server flag resolver must not ignore a partial rollout.
//
// The client resolves `rollout_percent` by bucketing SHA-256("<installId>:<key>")
// (app/lib/data/catalog/feature_flag_service.dart). This resolver ignored it, so
// a flag could be off for 90% of clients while every Edge Function treated it as
// fully on — a "staged" rollout that is not staged on the backend at all, and a
// kill switch that does not switch off the half that matters.
//
// The server cannot reproduce the client's cohort (client buckets on install_id,
// server knows only user_id), so agreeing exactly is impossible. Failing closed
// is the honest alternative: a partial rollout is simply not enabled
// server-side. It can never enable a feature for MORE users than intended.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { resolveUserBooleanFlag } from './feature_flags.ts';

type Row = Record<string, unknown> | null;

/** Minimal PostgREST stub: one row for feature_flags, one for the override. */
function stubClient(flagRow: Row, overrideRow: Row = null) {
  // deno-lint-ignore no-explicit-any
  const table = (row: Row): any => ({
    select: () => table(row),
    eq: () => table(row),
    maybeSingle: () => Promise.resolve({ data: row }),
  });
  // deno-lint-ignore no-explicit-any
  return {
    from: (name: string) =>
      table(name === 'feature_flags' ? flagRow : overrideRow),
  } as any;
}

const activeFlag = (extra: Record<string, unknown> = {}) => ({
  value: 'true',
  value_type: 'boolean',
  is_active: true,
  rollout_percent: 100,
  target_countries: [],
  ...extra,
});

Deno.test('a fully rolled-out active flag is enabled', async () => {
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag()),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, true);
});

Deno.test('C-10: a PARTIAL rollout is not enabled server-side', async () => {
  for (const percent of [1, 25, 50, 99]) {
    const got = await resolveUserBooleanFlag(
      stubClient(activeFlag({ rollout_percent: percent })),
      'enable_thing',
      'user-1',
    );
    assertEquals(
      got,
      false,
      `rollout_percent=${percent} must not read as fully enabled`,
    );
  }
});

Deno.test('C-10: rollout_percent = 0 is not enabled', async () => {
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag({ rollout_percent: 0 })),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, false);
});

Deno.test('C-10: a country-targeted flag is not assumed global', async () => {
  // This resolver has no country context, so it cannot evaluate the target and
  // must not treat "targeted at SA" as "enabled everywhere".
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag({ target_countries: ['SA'] })),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, false);
});

Deno.test('an empty target list still means global', async () => {
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag({ target_countries: [] })),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, true);
});

Deno.test('a per-user override still wins over a partial rollout', async () => {
  // An override is explicit operator intent about ONE user, not a population
  // estimate — it is the sanctioned way to enable a staged feature for a tester.
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag({ rollout_percent: 10 }), { enabled: true }),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, true);
});

Deno.test('a per-user override can also disable a fully rolled-out flag', async () => {
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag(), { enabled: false }),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, false);
});

Deno.test('an inactive flag stays disabled regardless of rollout', async () => {
  const got = await resolveUserBooleanFlag(
    stubClient(activeFlag({ is_active: false, rollout_percent: 100 })),
    'enable_thing',
    'user-1',
  );
  assertEquals(got, false);
});

Deno.test('a missing rollout_percent is treated as fully rolled out', async () => {
  // Older rows may predate the column; absent must not mean "off", or existing
  // enabled flags would silently switch off on deploy.
  const row = activeFlag();
  delete (row as Record<string, unknown>).rollout_percent;
  assertEquals(
    await resolveUserBooleanFlag(stubClient(row), 'enable_thing', 'user-1'),
    true,
  );
});
