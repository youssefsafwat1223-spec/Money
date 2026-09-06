import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';
import { sendCapturePush } from '../_shared/apns.ts';
import { timingSafeEqual } from '../_shared/capture_auth.ts';
import { anyDeviceRecentlyActive, isPushAllowed, loadNotificationPolicy } from '../_shared/notification_policy.ts';

// The client maps BudgetEntity.allExpensesCategoryId ('__all_expenses__') to
// this key when syncing budgets to user_budgets — see
// supabase_planning_support.dart serverCategoryKey().
const ALL_EXPENSES_CATEGORY_ID = 'all_expenses';

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
export async function handleEvaluateBudgets(req: Request): Promise<Response> {
  // Service-only endpoint (MALI-004): the DB webhook (migration 0057) sends
  // the service-role key from Vault as its Bearer token. Anything else —
  // including a perfectly valid ordinary user JWT — must be rejected, because
  // the body's record.user_id is trusted blindly below.
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
    .select('apns_token, apns_environment, install_id_hash, last_seen_at')
    .eq('user_id', userId)
    .not('apns_token', 'is', null);

  // MALI-061n — single-authority coordination. The LOCAL app fires the budget
  // alert immediately when it processes a transaction; this server path is only
  // the FALLBACK for when no device has been active recently (so the local
  // alert could not have fired). When a device IS recently active we still
  // advance the notified watermark (below) so the tier isn't re-pushed later,
  // but we do NOT push here — avoiding the local+server duplicate.
  const budgetFallbackWindowMs = 6 * 60 * 60 * 1000;
  const deviceRecentlyActive = anyDeviceRecentlyActive(
    (devices ?? []).map((d) => d.last_seen_at as string | null),
    Date.now(),
    budgetFallbackWindowMs,
  );

  // Server-side honoring of the user's notification preferences (MALI-019):
  // one load per request (userId is fixed here).
  const policy = await loadNotificationPolicy(supabase, userId);

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

    // Respect the per-type toggle + quiet hours before touching state or
    // sending (MALI-019). Over-100% = budget_over, otherwise budget_warning.
    // We skip the last_notified bump too, so re-enabling the toggle later
    // still surfaces the tier the user is currently in.
    const budgetType = bucket === 3 ? 'budget_over' : 'budget_warning';
    if (!isPushAllowed(policy, budgetType)) continue;

    // Advance the notified watermark regardless — an active local app is
    // assumed to have covered this tier, so it must not be re-pushed later.
    await supabase
      .from('user_budgets')
      .update({ last_notified_spent_amount: currentSpend })
      .eq('id', budget.id);

    // Local app is the primary authority when a device is active — don't
    // double-notify. Fall through to the server push only when inactive.
    if (deviceRecentlyActive) continue;

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
}

serve(handleEvaluateBudgets);
