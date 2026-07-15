import { corsHeaders, json, serviceClient, timingSafeEqual } from '../_shared/capture_auth.ts';

// Scheduled worker for the approved 30-day account deletion policy. Not wired
// to any automatic trigger yet — see docs/USER_DELETION_DECISION_BRIEF.md for
// why (calling the Storage API and the Auth Admin API requires an Edge
// Function; invoking one automatically from pg_cron would mean embedding a
// secret into a cron job's SQL text, which is a deliberate, separate
// operational decision, not something this change makes silently).
//
// Gated by a dedicated PURGE_WORKER_SECRET (set via `supabase secrets set`),
// not SUPABASE_SERVICE_ROLE_KEY: that name is platform-reserved and its value
// is rotated/managed by Supabase itself (confirmed to differ from the
// project's actual service-role JWT), so its plaintext isn't something a
// caller could ever be given to present back. The underlying purge_user_data()
// RPC is independently grant-restricted to service_role only, so this check
// is defense in depth, not the only gate.
//
// For each user whose profiles.delete_scheduled_at has elapsed: capture their
// backup blob path, hard-delete every row they own (purge_user_data), remove
// the Storage blob, then delete the auth.users row via the Admin API. Order
// matters — the blob path must be read before purge_user_data deletes the
// backups row that references it.

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

  const due = await supabase
    .from('profiles')
    .select('id, delete_scheduled_at')
    .not('delete_scheduled_at', 'is', null)
    .lt('delete_scheduled_at', new Date().toISOString());

  if (due.error) {
    return json({ error: 'due_query_failed', details: due.error.message }, 500);
  }

  const succeeded: string[] = [];
  const failed: Array<{ userId: string; stage: string; message: string }> = [];

  for (const row of due.data ?? []) {
    const userId = row.id as string;
    try {
      const backupRow = await supabase
        .from('backups')
        .select('blob_path')
        .eq('user_id', userId)
        .maybeSingle();
      if (backupRow.error) {
        failed.push({ userId, stage: 'read_backup', message: backupRow.error.message });
        continue;
      }
      const blobPath = backupRow.data?.blob_path as string | undefined;

      const purge = await supabase.rpc('purge_user_data', { p_user_id: userId });
      if (purge.error) {
        failed.push({ userId, stage: 'purge_user_data', message: purge.error.message });
        continue;
      }

      if (blobPath) {
        const removed = await supabase.storage.from('backups').remove([blobPath]);
        if (removed.error) {
          failed.push({ userId, stage: 'remove_storage_blob', message: removed.error.message });
          continue;
        }
      }

      const authDelete = await supabase.auth.admin.deleteUser(userId);
      if (authDelete.error) {
        failed.push({ userId, stage: 'delete_auth_user', message: authDelete.error.message });
        continue;
      }

      succeeded.push(userId);
    } catch (error) {
      failed.push({ userId, stage: 'unexpected', message: String(error).slice(0, 200) });
    }
  }

  return json({
    dueCount: (due.data ?? []).length,
    succeeded,
    failed,
  });
});
