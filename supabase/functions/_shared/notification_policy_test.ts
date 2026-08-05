import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  anyDeviceRecentlyActive,
  isPushAllowed,
  loadNotificationPolicy,
  type NotificationPolicy,
} from './notification_policy.ts';

const base: NotificationPolicy = {
  budgetWarning: true,
  budgetOver: true,
  goalMilestone: true,
  streakReminder: true,
  subscriptionReminder: true,
  quietHoursEnabled: false,
  quietHoursStartHour: 23,
  quietHoursEndHour: 8,
  utcOffsetHours: null,
};

Deno.test('per-type toggle suppresses only its own type', () => {
  const p = { ...base, streakReminder: false };
  assertEquals(isPushAllowed(p, 'streak_reminder'), false);
  assertEquals(isPushAllowed(p, 'bill_reminder'), true);
  assertEquals(isPushAllowed(p, 'budget_over'), true);
});

Deno.test('budget warning and over are independent toggles', () => {
  const p = { ...base, budgetWarning: false, budgetOver: true };
  assertEquals(isPushAllowed(p, 'budget_warning'), false);
  assertEquals(isPushAllowed(p, 'budget_over'), true);
});

Deno.test('quiet hours never fire without a known timezone offset', () => {
  // Unknown country → utcOffsetHours null → quiet hours cannot suppress.
  const p = { ...base, quietHoursEnabled: true, utcOffsetHours: null };
  const at3amUtc = new Date('2026-07-29T03:00:00Z');
  assertEquals(isPushAllowed(p, 'budget_over', at3amUtc), true);
});

Deno.test('quiet hours wrapping past midnight suppress inside the window', () => {
  // Riyadh (+3), quiet 23:00–08:00 local.
  const p = { ...base, quietHoursEnabled: true, utcOffsetHours: 3 };
  // 00:00 UTC = 03:00 local → inside quiet window → suppressed.
  assertEquals(
    isPushAllowed(p, 'budget_over', new Date('2026-07-29T00:00:00Z')),
    false,
  );
  // 21:00 local (18:00 UTC) → outside quiet window → allowed.
  assertEquals(
    isPushAllowed(p, 'budget_over', new Date('2026-07-29T18:00:00Z')),
    true,
  );
  // 22:59 local (19:59 UTC) → just before start → allowed.
  assertEquals(
    isPushAllowed(p, 'budget_over', new Date('2026-07-29T19:59:00Z')),
    true,
  );
  // 23:00 local (20:00 UTC) → start boundary is inclusive → suppressed.
  assertEquals(
    isPushAllowed(p, 'budget_over', new Date('2026-07-29T20:00:00Z')),
    false,
  );
  // 08:00 local (05:00 UTC) → end boundary is exclusive → allowed.
  assertEquals(
    isPushAllowed(p, 'budget_over', new Date('2026-07-29T05:00:00Z')),
    true,
  );
});

Deno.test('non-wrapping quiet window suppresses only within [start,end)', () => {
  const p = {
    ...base,
    quietHoursEnabled: true,
    utcOffsetHours: 0,
    quietHoursStartHour: 1,
    quietHoursEndHour: 6,
  };
  assertEquals(isPushAllowed(p, 'budget_over', new Date('2026-07-29T00:30:00Z')), true);
  assertEquals(isPushAllowed(p, 'budget_over', new Date('2026-07-29T03:00:00Z')), false);
  assertEquals(isPushAllowed(p, 'budget_over', new Date('2026-07-29T06:00:00Z')), true);
});

Deno.test('disabled type stays suppressed even outside quiet hours', () => {
  const p = { ...base, goalMilestone: false, quietHoursEnabled: true, utcOffsetHours: 3 };
  assertEquals(
    isPushAllowed(p, 'goal_milestone', new Date('2026-07-29T12:00:00Z')),
    false,
  );
});

Deno.test('loadNotificationPolicy parses notifications_json and maps country offset', async () => {
  const supabase = {
    from() {
      return {
        select() {
          return this;
        },
        eq() {
          return this;
        },
        is() {
          return this;
        },
        limit() {
          return this;
        },
        maybeSingle() {
          return Promise.resolve({
            data: {
              country: 'sa',
              notifications_json: JSON.stringify({
                streakReminder: false,
                quietHoursEnabled: true,
                quietHoursStartHour: 22,
                quietHoursEndHour: 7,
              }),
            },
            error: null,
          });
        },
      };
    },
  };
  // deno-lint-ignore no-explicit-any
  const policy = await loadNotificationPolicy(supabase as any, 'u1');
  assertEquals(policy.streakReminder, false);
  assertEquals(policy.budgetOver, true); // absent key → defaults enabled
  assertEquals(policy.quietHoursEnabled, true);
  assertEquals(policy.quietHoursStartHour, 22);
  assertEquals(policy.utcOffsetHours, 3); // SA → +3
});

Deno.test('loadNotificationPolicy fails open on malformed json', async () => {
  const supabase = {
    from() {
      return {
        select() {
          return this;
        },
        eq() {
          return this;
        },
        is() {
          return this;
        },
        limit() {
          return this;
        },
        maybeSingle() {
          return Promise.resolve({
            data: { country: 'EG', notifications_json: '{not json' },
            error: null,
          });
        },
      };
    },
  };
  // deno-lint-ignore no-explicit-any
  const policy = await loadNotificationPolicy(supabase as any, 'u1');
  // Malformed blob → default policy (all enabled, no quiet hours).
  assertEquals(policy.budgetOver, true);
  assertEquals(policy.quietHoursEnabled, false);
});

Deno.test('loadNotificationPolicy with no row returns defaults', async () => {
  const supabase = {
    from() {
      return {
        select() {
          return this;
        },
        eq() {
          return this;
        },
        is() {
          return this;
        },
        limit() {
          return this;
        },
        maybeSingle() {
          return Promise.resolve({ data: null, error: null });
        },
      };
    },
  };
  // deno-lint-ignore no-explicit-any
  const policy = await loadNotificationPolicy(supabase as any, 'u1');
  assertEquals(policy.budgetWarning, true);
  assertEquals(policy.utcOffsetHours, null);
});

Deno.test('anyDeviceRecentlyActive: local-primary budget coordination', () => {
  const now = Date.parse('2026-08-05T12:00:00Z');
  const hour = 3600_000;
  // A device seen 1h ago is recently active → server defers to the local app.
  assertEquals(
    anyDeviceRecentlyActive(['2026-08-05T11:00:00Z'], now, 6 * hour),
    true,
  );
  // All devices stale (> window) → server fallback fires.
  assertEquals(
    anyDeviceRecentlyActive(['2026-08-04T00:00:00Z', null], now, 6 * hour),
    false,
  );
  // No devices / missing timestamps → not active (server fallback).
  assertEquals(anyDeviceRecentlyActive([], now, 6 * hour), false);
  assertEquals(anyDeviceRecentlyActive([undefined, 'garbage'], now, 6 * hour), false);
});
