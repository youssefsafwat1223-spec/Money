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
// AUTH (migration 0099). Was `SUPABASE_SERVICE_ROLE_KEY`, a platform-reserved
// name whose value Supabase rotates and which differs from the project's real
// service-role JWT — no caller could present it, so this endpoint was
// unreachable. Same fix as 0053 applied to process-notification-retries.
//
// Its own secret, NOT the shared ENGAGEMENT_WORKER_SECRET: this endpoint is a
// retired no-op with no data access, so it must not carry a credential that
// would also unlock the three live evaluate-* functions. Least privilege is
// meaningful exactly here, where the capabilities genuinely differ.
//
// Fails closed: an empty configured secret rejects every request.
export function handleCronDailyReminders(req: Request): Response {
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('REMINDERS_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return new Response('Forbidden', { status: 403 });
  }
  // No pushes: streak + bill reminders are owned by the on-device scheduler.
  return new Response(
    JSON.stringify({ status: 'retired', authority: 'local_scheduled_reminders' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
}

serve(handleCronDailyReminders);
