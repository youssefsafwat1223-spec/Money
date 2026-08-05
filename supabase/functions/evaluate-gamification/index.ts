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

  // MALI-024 §5 — award each transaction AT MOST ONCE. The insert into the
  // idempotency ledger is the atomic guard: a webhook retry, duplicate delivery,
  // function retry, or a second concurrent worker all collide on the primary key
  // and return here without awarding, so XP/achievements/streak and the push are
  // never double-counted.
  if (!transaction.id) {
    return new Response('OK');
  }
  const claim = await supabase
    .from('gamification_awarded_transactions')
    .insert({ transaction_id: String(transaction.id), user_id: userId })
    .select('transaction_id')
    .maybeSingle();
  if (claim.error || !claim.data) {
    // Unique-violation (already awarded) or a write failure → do not award again.
    return new Response('OK');
  }

  // Award XP (e.g., 10 XP per transaction)
  const xpAward = 10;

  // Fetch current XP level
  const { data: xpLevelData } = await supabase
    .from('user_xp_levels')
    .select('*')
    .eq('user_id', userId)
    .single();

  let newXp = xpAward;
  let currentLevel = 1;
  let leveledUp = false;

  if (xpLevelData) {
    newXp = (xpLevelData.xp || 0) + xpAward;
    currentLevel = xpLevelData.level || 1;

    // Level formula e.g. level = floor(sqrt(xp / 100)) + 1
    const newLevel = Math.floor(Math.sqrt(newXp / 100)) + 1;
    if (newLevel > currentLevel) {
      leveledUp = true;
      currentLevel = newLevel;
    }

    await supabase
      .from('user_xp_levels')
      .update({ xp: newXp, level: currentLevel })
      .eq('user_id', userId);
  } else {
    await supabase
      .from('user_xp_levels')
      .insert({ user_id: userId, xp: newXp, level: currentLevel });
  }

  // Check achievements (1st, 10th, 100th transaction)
  const { count } = await supabase
    .from('user_transactions')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', userId);

  let achievementUnlocked = null;
  if (count === 1) achievementUnlocked = 'First Transaction!';
  else if (count === 10) achievementUnlocked = '10th Transaction!';
  else if (count === 100) achievementUnlocked = '100th Transaction Century!';

  // Dispatch APNs if needed
  if (leveledUp || achievementUnlocked) {
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
        body = `Congratulations! You reached Level ${currentLevel}!`;
      } else if (achievementUnlocked) {
        title = 'Achievement Unlocked! 🏆';
        body = `You unlocked: ${achievementUnlocked}`;
      }

      for (const device of devices) {
        await sendCapturePush({
          token: device.apns_token,
          environment: device.apns_environment as 'sandbox' | 'production',
          payloadId: crypto.randomUUID(),
          title,
          body,
          notificationType: 'gamification_alert',
        });
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
