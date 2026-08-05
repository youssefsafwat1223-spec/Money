import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';

// RETIRED (MALI-061n) — single-authority reconciliation.
//
// This sweep previously pushed streak_reminder and bill_reminder notifications
// to every device. Both are ALSO produced on-device as SCHEDULED LOCAL
// notifications (streak at 20:00 device-local, id 88008; bill reminders the day
// before at 10:00 device-local, ids [92000,992000)). The local schedule is the
// authoritative path: it fires via the OS even when the app is not running, is
// timezone-correct on the device, and applies the per-type preference + quiet
// hours locally. Running this server sweep in parallel produced a second,
// independent notification for the same business event (a duplicate) — and
// `anyDeviceRecentlyActive` cannot coordinate a scheduled-local notification,
// because a device idle for hours still fires its scheduled reminder.
//
// Per the closure decision, the redundant server authority is retired rather
// than wrapped in a fragile timing heuristic. The pg_cron dispatcher may keep
// invoking this endpoint; it authenticates and then no-ops. (Immediate,
// event-driven pushes — budgets, goals, achievements — keep their coordinated
// local-primary/server-fallback model in their own functions.)
serve((req) => {
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!serviceKey || !timingSafeEqual(token, serviceKey)) {
    return new Response('Forbidden', { status: 403 });
  }
  // No pushes: streak + bill reminders are owned by the on-device scheduler.
  return new Response(
    JSON.stringify({ status: 'retired', authority: 'local_scheduled_reminders' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
