import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';

serve(async (req) => {
  const payload = await req.json();
  const contribution = payload.record;
  if (!contribution || !contribution.goal_id) {
    return new Response('OK');
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  // Fetch the goal
  const { data: goal } = await supabase
    .from('user_goals')
    .select('*')
    .eq('id', contribution.goal_id)
    .single();

  if (!goal || !goal.target_amount) {
    return new Response('OK');
  }

  const targetAmount = goal.target_amount;
  // Sum contributions or use existing goal.total_saved if maintained
  const { data: sumData } = await supabase
    .from('goal_contributions')
    .select('amount')
    .eq('goal_id', goal.id);

  const totalSaved = (sumData || []).reduce((sum, c) => sum + (c.amount || 0), 0);
  const lastNotified = goal.last_notified_saved_amount || 0;

  const currentPercent = totalSaved / targetAmount;
  const lastNotifiedPercent = lastNotified / targetAmount;

  // Find highest 25% milestone crossed
  const milestones = [1.0, 0.75, 0.5, 0.25];
  let crossedMilestone = null;

  for (const m of milestones) {
    if (currentPercent >= m && lastNotifiedPercent < m) {
      crossedMilestone = m;
      break; // highest first
    }
  }

  if (crossedMilestone) {
    // Update goal
    await supabase
      .from('user_goals')
      .update({ last_notified_saved_amount: totalSaved })
      .eq('id', goal.id);

    // Send Push notification
    const { data: devices } = await supabase
      .from('capture_devices')
      .select('apns_token, apns_environment')
      .eq('user_id', goal.user_id)
      .not('apns_token', 'is', null);

    if (devices && devices.length > 0) {
      const milestoneText = `${Math.round(crossedMilestone * 100)}%`;
      for (const device of devices) {
        await sendCapturePush({
          token: device.apns_token,
          environment: device.apns_environment as any,
          payloadId: crypto.randomUUID(),
          title: 'Goal Milestone Reached! 🎉',
          body: `You've reached ${milestoneText} of your goal "${goal.name || 'Savings Goal'}"!`,
          notificationType: 'goal_milestone'
        });
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
