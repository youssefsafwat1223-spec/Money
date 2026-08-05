import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';
import { anyDeviceRecentlyActive, isPushAllowed, loadNotificationPolicy } from '../_shared/notification_policy.ts';

serve(async (req) => {
  // Service-only endpoint (MALI-004): only the DB webhook's service-role
  // Bearer may drive goal notifications — record fields are trusted below.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!serviceKey || !timingSafeEqual(token, serviceKey)) {
    return new Response('Forbidden', { status: 403 });
  }

  const payload = await req.json();
  // Trigger fires AFTER UPDATE ON user_goals, so `record` is the goal row
  // itself (with its already-current saved_amount) — not a contribution row.
  const goal = payload.record;
  if (!goal || !goal.id || !goal.target_amount) {
    return new Response('OK');
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  const targetAmount = goal.target_amount;
  const totalSaved = goal.saved_amount || 0;
  const lastNotified = goal.last_notified_saved_amount || 0;

  const currentPercent = totalSaved / targetAmount;
  const lastNotifiedPercent = lastNotified / targetAmount;

  // Find highest 25% milestone crossed since the last notification.
  const milestones = [1.0, 0.75, 0.5, 0.25];
  let crossedMilestone = null;

  for (const m of milestones) {
    if (currentPercent >= m && lastNotifiedPercent < m) {
      crossedMilestone = m;
      break; // highest first
    }
  }

  if (crossedMilestone) {
    // Respect the goal-milestone toggle + quiet hours (MALI-019). Skip the
    // last_notified bump when suppressed so re-enabling still surfaces it.
    const policy = await loadNotificationPolicy(supabase, goal.user_id);
    if (!isPushAllowed(policy, 'goal_milestone')) {
      return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
    }

    // Advance the notified watermark regardless (durable de-dup state), so the
    // milestone is not re-evaluated later even if the push is suppressed here.
    await supabase
      .from('user_goals')
      .update({ last_notified_saved_amount: totalSaved })
      .eq('id', goal.id);

    const { data: devices } = await supabase
      .from('capture_devices')
      .select('apns_token, apns_environment, last_seen_at')
      .eq('user_id', goal.user_id)
      .not('apns_token', 'is', null);
    if (!devices || devices.length === 0) {
      return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
    }

    // MALI-061n coordination — the LOCAL app is the PRIMARY goal-milestone
    // authority (it notifies immediately when a contribution is added on an
    // active device). The server is the FALLBACK that pushes only when NO device
    // has been active recently, so the same milestone is never double-notified.
    const fallbackWindowMs = 6 * 60 * 60 * 1000;
    if (
      anyDeviceRecentlyActive(
        devices.map((d) => d.last_seen_at as string | null),
        Date.now(),
        fallbackWindowMs,
      )
    ) {
      return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
    }

    const privacy = policy.hideLockScreenContent;
    const milestoneText = `${Math.round(crossedMilestone * 100)}`;
    const title = privacy ? 'قرش' : `خزنة ${goal.name || 'هدفك'} وصلت ${milestoneText}%!`;
    const body = privacy ? 'لديك تحديث جديد. افتح التطبيق للمزيد.' : 'أداء ممتاز، أنت في المسار الصحيح.';
    for (const device of devices) {
      // Stable per-goal-milestone collapse id shared with the local authority's
      // business key — a retry/overlap collapses instead of duplicating.
      await sendCapturePush({
        token: device.apns_token,
        environment: device.apns_environment as 'sandbox' | 'production',
        payloadId: `goal:${goal.id}:${Math.round(crossedMilestone * 100)}`,
        title,
        body,
        notificationType: 'goal_milestone',
      });
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
