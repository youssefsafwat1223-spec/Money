import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';
import { anyDeviceRecentlyActive, isPushAllowed, loadNotificationPolicy } from '../_shared/notification_policy.ts';

// AUTH (migration 0099). This previously compared the caller's bearer against
// `SUPABASE_SERVICE_ROLE_KEY`. That name is PLATFORM-RESERVED: Supabase manages
// and rotates its value, and it differs from the project's real service-role
// JWT — so no caller, including the pg trigger dispatcher, could ever present
// it back. The comparison could therefore never succeed and this function was
// unreachable in production. Migration 0053 already solved exactly this for
// process-notification-retries, and purge-scheduled-deletions before it; this
// applies the same dedicated-worker-secret contract.
//
// The three evaluate-* functions SHARE one secret: they are one trust domain —
// same caller (the 0057 trigger layer), same capability (forge a push for an
// arbitrary user_id), same rotation lifecycle. Splitting them would not reduce
// blast radius, because all copies live in the same Vault and the same Edge
// env, so a compromise yielding one yields all three. cron-daily-reminders is
// deliberately NOT in this domain and holds its own secret.
//
// Fails closed: an empty configured secret rejects every request.
export async function handleEvaluateGamification(req: Request): Promise<Response> {
  // Service-only endpoint (MALI-004): only the DB webhook's service-role
  // Bearer may drive XP awards — record.user_id is trusted blindly below.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('ENGAGEMENT_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return new Response('Forbidden', { status: 403 });
  }

  const payload = await req.json();
  const transaction = payload.record;
  if (!transaction || !transaction.user_id) {
    return new Response('OK');
  }

  const userId = transaction.user_id;
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  if (!transaction.id) {
    return new Response('OK');
  }

  // MALI-024 §5 — award atomically, EXACTLY ONCE. The RPC folds the idempotency
  // claim and the XP / level / achievement / notification-eligibility write into
  // ONE Postgres transaction, so a crash rolls the claim back together with the
  // award (no lost or partial award), a webhook retry / duplicate delivery /
  // function retry / lost response reconstructs the stored canonical result, and
  // two concurrent workers serialise on the claim row lock — never double-count.
  const { data: award, error: awardError } = await supabase.rpc(
    'award_gamification_for_transaction',
    { p_transaction_id: String(transaction.id), p_user_id: userId },
  );
  if (awardError || !award || award.awarded !== true) {
    // Not owned / transient error → do not award; the webhook may retry safely.
    return new Response('OK');
  }

  const leveledUp = award.leveled_up === true;
  const achievementCode: string | null = award.achievement ?? null;
  const ok = () => new Response('OK', { headers: { 'Content-Type': 'application/json' } });
  if (!leveledUp && !achievementCode) return ok();

  // MALI-019 — the notification generated after the award must pass the
  // server-authoritative notification-policy contract before ANY provider
  // delivery. Notification ELIGIBILITY was already recorded exactly-once inside
  // the award transaction (0074); this gate governs only best-effort DELIVERY,
  // which happens after the commit and never re-awards. Preference OFF or quiet
  // hours ⇒ no push (defer-or-suppress). Caller-supplied preference/quiet-hours/
  // privacy values are never authoritative — the policy is loaded server-side.
  const policy = await loadNotificationPolicy(supabase, userId);
  if (!isPushAllowed(policy, 'achievement')) return ok();

  const { data: devices } = await supabase
    .from('capture_devices')
    .select('apns_token, apns_environment, last_seen_at')
    .eq('user_id', userId)
    .not('apns_token', 'is', null);
  if (!devices || devices.length === 0) return ok();

  // MALI-061n coordination — the LOCAL app is the PRIMARY achievement authority
  // (gamification_sync notifies on pull when a device is active). The server is
  // the FALLBACK that pushes only when NO device has been active recently, so we
  // never generate a local+server duplicate for the same award.
  const fallbackWindowMs = 6 * 60 * 60 * 1000;
  if (
    anyDeviceRecentlyActive(
      devices.map((d) => d.last_seen_at as string | null),
      Date.now(),
      fallbackWindowMs,
    )
  ) {
    return ok();
  }

  // Lock-screen privacy — redacted mode carries GENERIC content only (no XP,
  // level, achievement name, or any financial text). Sourced from the server-
  // owned policy, never a caller-supplied flag.
  let title: string;
  let body: string;
  if (policy.hideLockScreenContent) {
    title = 'قرش';
    body = 'لديك تحديث جديد. افتح التطبيق للمزيد.';
  } else if (leveledUp) {
    title = 'Level Up! 🌟';
    body = `Congratulations! You reached Level ${award.level}!`;
  } else {
    const achievementLabels: Record<string, string> = {
      first_transaction: 'First Transaction!',
      tenth_transaction: '10th Transaction!',
      century_transaction: '100th Transaction Century!',
    };
    title = 'Achievement Unlocked! 🏆';
    body = `You unlocked: ${achievementLabels[achievementCode!] ?? achievementCode}`;
  }

  // Delivery is best-effort and AFTER the committed award. The payloadId is
  // stable per transaction, so APNs collapses a retry into the same notification
  // (banner-replacement, not strict delivery idempotency): provider failure
  // stays retryable, a repeat cannot create a second eligibility row, and a send
  // failure never rolls back or re-awards. APNs acceptance is not marked as
  // displayed/delivered.
  for (const device of devices) {
    await sendCapturePush({
      token: device.apns_token,
      environment: device.apns_environment as 'sandbox' | 'production',
      payloadId: `gamification:${transaction.id}`,
      title,
      body,
      notificationType: 'gamification_alert',
    });
  }

  return ok();
}

serve(handleEvaluateGamification);
