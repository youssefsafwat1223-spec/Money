import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';

serve(async () => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);

  // 1. Check user_streaks where last_active_date < today
  const { data: streaks } = await supabase
    .from('user_streaks')
    .select('user_id, last_active_date, current_streak')
    .lt('last_active_date', today.toISOString());

  if (streaks && streaks.length > 0) {
    for (const streak of streaks) {
      const { data: devices } = await supabase
        .from('capture_devices')
        .select('apns_token, apns_environment')
        .eq('user_id', streak.user_id)
        .not('apns_token', 'is', null);
      
      if (devices) {
        for (const device of devices) {
          await sendCapturePush({
            token: device.apns_token,
            environment: device.apns_environment as any,
            payloadId: crypto.randomUUID(),
            title: 'Keep Your Streak Alive! 🔥',
            body: `You are on a ${streak.current_streak}-day streak! Log in today to keep it going.`,
            notificationType: 'streak_reminder'
          });
        }
      }
    }
  }

  // 2. Check user_subscriptions (bills) due in next 3 days where is_confirmed = false
  const in3Days = new Date(today);
  in3Days.setDate(in3Days.getDate() + 3);

  const { data: subscriptions } = await supabase
    .from('user_subscriptions')
    .select('user_id, name, next_due_date, amount')
    .eq('is_confirmed', false)
    .gte('next_due_date', today.toISOString())
    .lte('next_due_date', in3Days.toISOString());

  if (subscriptions && subscriptions.length > 0) {
    for (const sub of subscriptions) {
      const { data: devices } = await supabase
        .from('capture_devices')
        .select('apns_token, apns_environment')
        .eq('user_id', sub.user_id)
        .not('apns_token', 'is', null);

      if (devices) {
        for (const device of devices) {
          await sendCapturePush({
            token: device.apns_token,
            environment: device.apns_environment as any,
            payloadId: crypto.randomUUID(),
            title: 'Upcoming Bill Reminder 🗓',
            body: `${sub.name || 'A bill'} of ${sub.amount} is due soon. Make sure it's covered!`,
            notificationType: 'bill_reminder'
          });
        }
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
