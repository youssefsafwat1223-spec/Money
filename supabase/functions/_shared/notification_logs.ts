// Shared notification_logs writes for the APNs channel — used by both
// process-ios-sms (first attempt) and process-notification-retries (bounded
// retries). See docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
//
// IMPORTANT: APNs gives no delivery receipt. 'sent' here means "Apple's
// HTTP/2 API accepted the request," never "the device displayed it."
//
// Never pass raw SMS text or the device token into `payload` — it is
// diagnostics/routing-only (title/body omitted deliberately; only routing
// keys and the APNs response id belong here).

// deno-lint-ignore no-explicit-any
type SupabaseClientLike = any;

export async function upsertQueuedApnsLog(
  supabase: SupabaseClientLike,
  input: {
    id: string;
    userId: string | null;
    installId: string;
    notificationType: string;
    relatedEntityType?: string;
    relatedEntityId?: string;
    devicePlatform?: string;
    apnsEnvironment?: string;
  },
): Promise<void> {
  const now = new Date().toISOString();
  await supabase.from('notification_logs').upsert({
    id: input.id,
    user_id: input.userId,
    install_id: input.installId,
    notification_type: input.notificationType,
    channel: 'apns',
    status: 'queued',
    queued_at: now,
    related_entity_type: input.relatedEntityType ?? null,
    related_entity_id: input.relatedEntityId ?? null,
    device_platform: input.devicePlatform ?? 'ios',
    apns_environment: input.apnsEnvironment ?? null,
  }, { onConflict: 'id' });
}

export async function markApnsLogSent(
  supabase: SupabaseClientLike,
  id: string,
  apnsId: string | null,
): Promise<void> {
  await supabase.from('notification_logs').update({
    status: 'sent',
    sent_at: new Date().toISOString(),
    payload: apnsId ? { apnsId } : {},
  }).eq('id', id);
}

export async function markApnsLogFailed(
  supabase: SupabaseClientLike,
  id: string,
  input: { errorCode: string; errorReason: string; retryCount: number },
): Promise<void> {
  await supabase.from('notification_logs').update({
    status: 'failed',
    failed_at: new Date().toISOString(),
    error_code: input.errorCode,
    error_reason: input.errorReason.slice(0, 500),
    retry_count: input.retryCount,
  }).eq('id', id);
}
