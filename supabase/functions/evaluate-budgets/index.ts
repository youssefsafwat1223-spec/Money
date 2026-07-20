import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';

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

  // 1. Fetch active budgets for this user
  const { data: budgets } = await supabase
    .from('user_budgets')
    .select('*')
    .eq('user_id', userId)
    .eq('status', 'active');

  if (!budgets || budgets.length === 0) {
    return new Response('OK');
  }

  // 2. Fetch APNs tokens
  const { data: devices } = await supabase
    .from('capture_devices')
    .select('apns_token, apns_environment, install_id_hash')
    .eq('user_id', userId)
    .not('apns_token', 'is', null);

  for (const budget of budgets) {
    // Assuming user_transactions are linked to a budget category or we sum all? 
    // The prompt says: Calculates the current spent amount for the affected user's active budgets.
    // If we just use budget.current_spend (assuming the DB trigger updates it), but the prompt says:
    // "Calculates the current spent amount for the affected user's active budgets."
    
    // We will sum the amount from transactions for the budget's category.
    const { data: txs } = await supabase
      .from('user_transactions')
      .select('amount')
      .eq('user_id', userId)
      .eq('category_id', budget.category_id);
    
    const currentSpend = (txs || []).reduce((sum, tx) => sum + (tx.amount || 0), 0);
    const lastNotified = budget.last_notified_spent_amount || 0;
    const thresholdIncrement = budget.amount * 0.1;

    if (currentSpend >= budget.amount && currentSpend >= lastNotified + thresholdIncrement) {
      // Update last_notified_spent_amount
      await supabase
        .from('user_budgets')
        .update({ last_notified_spent_amount: currentSpend })
        .eq('id', budget.id);

      // Send Push notification
      if (devices && devices.length > 0) {
        for (const device of devices) {
          await sendCapturePush({
            token: device.apns_token,
            environment: device.apns_environment as any,
            payloadId: crypto.randomUUID(),
            title: 'Budget Exceeded 🚨',
            body: `You've spent ${currentSpend} on ${budget.name || 'your budget'}, exceeding your limit of ${budget.amount}.`,
            notificationType: 'budget_alert'
          });
        }
      }
    }
  }

  return new Response('OK', { headers: { 'Content-Type': 'application/json' } });
});
