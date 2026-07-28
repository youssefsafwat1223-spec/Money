import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';
import { isPushAllowed, loadNotificationPolicy } from '../_shared/notification_policy.ts';

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

    await supabase
      .from('user_goals')
      .update({ last_notified_saved_amount: totalSaved })
      .eq('id', goal.id);

    const { data: devices } = await supabase
      .from('capture_devices')
      .select('apns_token, apns_environment')
      .eq('user_id', goal.user_id)
      .not('apns_token', 'is', null);

    if (devices && devices.length > 0) {
      const milestoneText = `${Math.round(crossedMilestone * 100)}`;
      for (const device of devices) {
        await sendCapturePush({
          token: device.apns_token,
          environment: device.apns_environment as any,
          payloadId: crypto.randomUUID(),
          title: `خزنة ${goal.name || 'هدفك'} وصلت ${milestoneText}%!`,
          body: 'أداء ممتاز، أنت في المسار الصحيح.',
          notificationType: 'goal_milestone',
        });
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
