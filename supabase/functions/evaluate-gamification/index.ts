import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';

serve(async (req) => {
  // Service-only endpoint (MALI-004): only the DB webhook's service-role
  // Bearer may drive XP awards — record.user_id is trusted blindly below.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!serviceKey || !timingSafeEqual(token, serviceKey)) {
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
  const achievementLabels: Record<string, string> = {
    first_transaction: 'First Transaction!',
    tenth_transaction: '10th Transaction!',
    century_transaction: '100th Transaction Century!',
  };

  // Notification delivery happens AFTER the award has committed — never inside
  // the transaction. The payloadId is stable per transaction, so APNs collapses
  // a retry into the same notification: provider failure stays retryable, a
  // repeat can never create a duplicate, and a send failure never rolls back or
  // re-awards (the award is already durably committed above).
  if (leveledUp || achievementCode) {
    const { data: devices } = await supabase
      .from('capture_devices')
      .select('apns_token, apns_environment')
      .eq('user_id', userId)
      .not('apns_token', 'is', null);

    if (devices && devices.length > 0) {
      let body = '';
      let title = '';
      if (leveledUp) {
        title = 'Level Up! 🌟';
        body = `Congratulations! You reached Level ${award.level}!`;
      } else if (achievementCode) {
        title = 'Achievement Unlocked! 🏆';
        body = `You unlocked: ${achievementLabels[achievementCode] ?? achievementCode}`;
      }

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
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
