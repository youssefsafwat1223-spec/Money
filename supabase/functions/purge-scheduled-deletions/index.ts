import { corsHeaders, json, serviceClient, timingSafeEqual } from '../_shared/capture_auth.ts';

// Scheduled worker for the approved 30-day account deletion policy.
//
// Wired automatically since migration 0065: a daily pg_cron job calls
// public.run_purge_scheduled_deletions(), which posts here with the
// PURGE_WORKER_SECRET from Vault. The secret is dedicated (set via
// `supabase secrets set PURGE_WORKER_SECRET=...`), not the service-role key —
// the underlying purge_user_data() RPC is independently grant-restricted to
// service_role only, so this check is defense in depth, not the only gate.
//
// Durable saga (MALI-005): deletion spans three systems (SQL, Storage, Auth
// Admin) that cannot share a transaction. Every other user table cascades from
// auth.users, so the old "purge SQL first" ordering destroyed the discovery
// row (profiles.delete_scheduled_at) before the fallible Storage/auth steps —
// one late failure orphaned the auth user and blob forever.
//
// Now `account_purge_queue` (no FK to auth.users — it survives everything)
// tracks per-step completion:
//
//   enqueue due profiles  → capture blob path while it still exists
//   step 1: storage       → remove backup blob   (missing blob = success)
//   step 2: sql           → purge_user_data RPC  (single transaction)
//   step 3: auth          → auth.admin.deleteUser (user-not-found = success)
//   done                  → delete the queue row
//
// A failure at any step records stage/error/attempts and leaves the queue row
// in place; the next run resumes at the first incomplete step. Every step is
// idempotent, so re-running after a crash between step and bookkeeping is safe.

type QueueRow = {
  user_id: string;
  blob_path: string | null;
  storage_deleted_at: string | null;
  sql_purged_at: string | null;
  auth_deleted_at: string | null;
  attempts: number;
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('PURGE_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return json({ error: 'forbidden' }, 403);
  }

  const supabase = serviceClient();
  const nowIso = () => new Date().toISOString();

  // ── Enqueue newly due accounts ────────────────────────────────────────────
  // Capture the backup blob path at enqueue time: after the SQL purge (or the
  // auth cascade) the backups metadata row that references it is gone.
  const due = await supabase
    .from('profiles')
    .select('id, delete_scheduled_at')
    .not('delete_scheduled_at', 'is', null)
    .lt('delete_scheduled_at', nowIso());
  if (due.error) {
    return json({ error: 'due_query_failed', details: due.error.message }, 500);
  }

  for (const row of due.data ?? []) {
    const userId = row.id as string;
    const backupRow = await supabase
      .from('backups')
      .select('blob_path')
      .eq('user_id', userId)
      .maybeSingle();
    // On a read error enqueue anyway with a null path: erasure must not be
    // blocked by backup metadata, and the storage step treats null as done.
    const blobPath = backupRow.error ? null : (backupRow.data?.blob_path as string | undefined);
    const inserted = await supabase
      .from('account_purge_queue')
      .upsert(
        { user_id: userId, blob_path: blobPath ?? null },
        { onConflict: 'user_id', ignoreDuplicates: true },
      );
    if (inserted.error) {
      return json({ error: 'enqueue_failed', details: inserted.error.message }, 500);
    }
  }

  // ── Process the queue (includes rows left over from previous runs) ────────
  const queue = await supabase
    .from('account_purge_queue')
    .select('user_id, blob_path, storage_deleted_at, sql_purged_at, auth_deleted_at, attempts')
    .order('enqueued_at', { ascending: true })
    .limit(100);
  if (queue.error) {
    return json({ error: 'queue_query_failed', details: queue.error.message }, 500);
  }

  const succeeded: string[] = [];
  const failed: Array<{ userId: string; stage: string; message: string }> = [];

  const markStep = (userId: string, patch: Record<string, unknown>) =>
    supabase.from('account_purge_queue').update(patch).eq('user_id', userId);

  const markFailure = async (userId: string, attempts: number, stage: string, message: string) => {
    failed.push({ userId, stage, message });
    await markStep(userId, {
      attempts: attempts + 1,
      last_stage: stage,
      last_error: message.slice(0, 500),
    });
  };

  for (const item of (queue.data ?? []) as QueueRow[]) {
    const userId = item.user_id;
    try {
      // Step 1 — Storage blob. A missing object is success (already removed).
      if (!item.storage_deleted_at) {
        if (item.blob_path) {
          const removed = await supabase.storage.from('backups').remove([item.blob_path]);
          // `remove` reports missing objects in-band, not as an error; a real
          // error (network/policy) must keep the step incomplete.
          if (removed.error) {
            await markFailure(userId, item.attempts, 'remove_storage_blob', removed.error.message);
            continue;
          }
        }
        const marked = await markStep(userId, { storage_deleted_at: nowIso() });
        if (marked.error) {
          await markFailure(userId, item.attempts, 'mark_storage', marked.error.message);
          continue;
        }
      }

      // Step 2 — SQL purge (one transaction inside the RPC). Runs before the
      // auth deletion so a mid-saga crash still leaves the profiles row for
      // operators; the queue row, not profiles, is the retry handle.
      if (!item.sql_purged_at) {
        const purge = await supabase.rpc('purge_user_data', { p_user_id: userId });
        if (purge.error) {
          await markFailure(userId, item.attempts, 'purge_user_data', purge.error.message);
          continue;
        }
        const marked = await markStep(userId, { sql_purged_at: nowIso() });
        if (marked.error) {
          await markFailure(userId, item.attempts, 'mark_sql', marked.error.message);
          continue;
        }
      }

      // Step 3 — Auth admin deletion. "User not found" means a previous run
      // already deleted it — that is success, not failure (idempotent retry).
      if (!item.auth_deleted_at) {
        const authDelete = await supabase.auth.admin.deleteUser(userId);
        const message = authDelete.error?.message ?? '';
        const alreadyGone = authDelete.error != null && /not.?found/i.test(message);
        if (authDelete.error && !alreadyGone) {
          await markFailure(userId, item.attempts, 'delete_auth_user', message);
          continue;
        }
        const marked = await markStep(userId, { auth_deleted_at: nowIso() });
        if (marked.error) {
          await markFailure(userId, item.attempts, 'mark_auth', marked.error.message);
          continue;
        }
      }

      // All steps complete — retire the saga row.
      const done = await supabase.from('account_purge_queue').delete().eq('user_id', userId);
      if (done.error) {
        await markFailure(userId, item.attempts, 'dequeue', done.error.message);
        continue;
      }
      succeeded.push(userId);
    } catch (error) {
      await markFailure(userId, item.attempts, 'unexpected', String(error));
    }
  }

  return json({
    dueCount: (due.data ?? []).length,
    queueCount: (queue.data ?? []).length,
    succeeded,
    failed,
  });
});
