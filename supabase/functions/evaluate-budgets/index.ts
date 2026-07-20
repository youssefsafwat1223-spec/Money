import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';

const ALL_EXPENSES_CATEGORY_ID = '__all_expenses__';

serve(async (req) => {
  const payload = await req.json();
  const transaction = payload.record;
  if (!transaction || !transaction.user_id) {
    return new Response('OK');
  }

  const userId = transaction.user_id;

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  const { data: budgets } = await supabase
    .from('user_budgets')
    .select('*')
    .eq('user_id', userId)
    .eq('is_active', true)
    .is('deleted_at', null);

  if (!budgets || budgets.length === 0) {
    return new Response('OK');
  }

  const { data: devices } = await supabase
    .from('capture_devices')
    .select('apns_token, apns_environment, install_id_hash')
    .eq('user_id', userId)
    .not('apns_token', 'is', null);

  for (const budget of budgets) {
    if (!budget.amount || budget.amount <= 0) continue;

    // Scoped to the budget's current period (client resets start_date on
    // rollover), so this doesn't sum spend across every past period.
    let query = supabase
      .from('user_transactions')
      .select('amount')
      .eq('user_id', userId)
      .eq('transaction_type', 'expense')
      .is('deleted_at', null)
      .gte('occurred_at', budget.start_date);

    if (budget.category_id !== ALL_EXPENSES_CATEGORY_ID) {
      if (budget.user_category_id) {
        query = query.eq('user_category_id', budget.user_category_id);
      } else {
        query = query.eq('category_id', budget.category_id);
      }
    }
    if (budget.server_account_id) {
      query = query.eq('server_account_id', budget.server_account_id);
    }

    const { data: txs } = await query;

    const currentSpend = (txs || []).reduce((sum, tx) => sum + (tx.amount || 0), 0);
    const lastNotified = budget.last_notified_spent_amount || 0;

    // Three thresholds: 75% / 90% / over 100% — same tiers the on-device
    // checker uses. Only fire on entering a *new*, higher tier than the one
    // already notified, or (once over 100%) every further +10% of budget
    // spent, so a single transaction doesn't spam repeat alerts.
    const bucketFor = (spend: number) =>
      spend >= budget.amount ? 3 : spend >= budget.amount * 0.9 ? 2 : spend >= budget.amount * 0.75 ? 1 : 0;
    const bucket = bucketFor(currentSpend);
    if (bucket === 0) continue;
    const lastBucket = bucketFor(lastNotified);
    const crossedNewTier = bucket > lastBucket;
    const grewFurtherPastOver = bucket === 3 && lastBucket === 3 && currentSpend >= lastNotified + budget.amount * 0.1;
    if (!crossedNewTier && !grewFurtherPastOver) continue;

    let title: string;
    let body: string;
    if (bucket === 3) {
      title = 'تجاوزت ميزانيتك';
      body = `صرفت ${currentSpend.toFixed(0)} زيادة عن ميزانيتك (${budget.amount.toFixed(0)}).`;
    } else if (bucket === 2) {
      title = 'ميزانيتك على وشك الاكتمال';
      body = `بقيلك ${(budget.amount - currentSpend).toFixed(0)} فقط من ميزانيتك (${budget.amount.toFixed(0)}).`;
    } else {
      title = 'وصلت ٧٥٪ من ميزانيتك';
      body = `صرفت ${currentSpend.toFixed(0)} من ${budget.amount.toFixed(0)}.`;
    }

    await supabase
      .from('user_budgets')
      .update({ last_notified_spent_amount: currentSpend })
      .eq('id', budget.id);

    if (devices && devices.length > 0) {
      for (const device of devices) {
        await sendCapturePush({
          token: device.apns_token,
          environment: device.apns_environment as 'sandbox' | 'production',
          payloadId: crypto.randomUUID(),
          title,
          body,
          notificationType: 'budget_alert',
        });
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
