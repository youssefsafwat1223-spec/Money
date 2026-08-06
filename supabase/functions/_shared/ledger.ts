import { serviceClient } from './capture_auth.ts';
import { resolveUserBooleanFlag } from './feature_flags.ts';

export interface LedgerWritePayload {
  payloadId: string;
  amount: number;
  currency: string;
  direction?: string;
  type?: string;
  merchant?: string;
  categoryId?: string;
  occurredAt: string;
  confidence?: number;
  last4?: string;
  status?: 'confirmed' | 'pending';
  balanceAfter?: number;
  comparisonTimestamp?: string;
  comparisonTimestampSource?: 'sms_body' | 'received_at';
  transactionTimeFromSms?: string;
  smsReceivedAt?: string;
  parserSource?: string;
}

export interface LedgerWriteResult {
  id: string;
  created: boolean;
}

export function isLedgerDualWriteEnabled(
  supabase: ReturnType<typeof serviceClient>,
  userId: string | null,
): Promise<boolean> {
  // Returns the resolver's Promise directly (no await needed here).
  return resolveUserBooleanFlag(supabase, 'ledger_dual_write', userId, {
    requireUser: true,
  });
}

export async function isDirectCaptureWriteEnabled(
  supabase: ReturnType<typeof serviceClient>,
  userId: string | null,
): Promise<boolean> {
  if (!userId) return false;
  const [captureEnabled, transactionsPrimary] = await Promise.all([
    resolveUserBooleanFlag(supabase, 'capture_direct_supabase_write', userId, {
      requireUser: true,
    }),
    resolveUserBooleanFlag(supabase, 'transactions_supabase_primary', userId, {
      requireUser: true,
    }),
  ]);
  return captureEnabled && transactionsPrimary;
}

// direction: debit|credit|unknown. Preserves the parser's own direction
// signal when present; otherwise infers from its type vocabulary
// (payment/withdrawal/transfer/refund/income/unknown).
function mapDirection(direction?: string, type?: string): 'debit' | 'credit' | 'unknown' {
  const d = (direction ?? '').toLowerCase();
  if (d === 'credit' || d === 'debit') return d;
  const t = (type ?? '').toLowerCase();
  if (['income', 'refund', 'deposit', 'received'].includes(t)) return 'credit';
  if (['payment', 'withdrawal', 'purchase', 'charged', 'paid'].includes(t)) return 'debit';
  return 'unknown';
}

// transaction_type: income|expense|transfer|refund|adjustment|unknown.
// Explicit classification from the parser (transfer/refund/income/etc.)
// always wins; debit/credit direction is only used as the last-resort
// default (debit→expense, credit→income) when the parser gave no usable type.
function mapTransactionType(
  direction?: string,
  type?: string,
): 'income' | 'expense' | 'transfer' | 'refund' | 'adjustment' | 'unknown' {
  const t = (type ?? '').toLowerCase();
  if (t === 'transfer') return 'transfer';
  if (t === 'refund') return 'refund';
  if (t === 'adjustment') return 'adjustment';
  if (['income', 'deposit', 'received'].includes(t)) return 'income';
  if (['payment', 'purchase', 'charged', 'paid', 'withdrawal'].includes(t)) return 'expense';
  switch (mapDirection(direction, type)) {
    case 'credit':
      return 'income';
    case 'debit':
      return 'expense';
    default:
      return 'unknown';
  }
}

export async function upsertLedgerTransaction(
  supabase: ReturnType<typeof serviceClient>,
  userId: string,
  payload: LedgerWritePayload,
): Promise<LedgerWriteResult> {
  const metadata: Record<string, unknown> = {
    transaction_source: 'bank',
    duplicate_status: 'normal',
  };
  if (payload.last4) metadata.last4 = payload.last4;
  if (payload.transactionTimeFromSms) {
    metadata.transaction_time_from_sms = payload.transactionTimeFromSms;
  }
  if (payload.smsReceivedAt) metadata.sms_received_at = payload.smsReceivedAt;
  if (payload.comparisonTimestamp) {
    metadata.comparison_timestamp = payload.comparisonTimestamp;
  }
  if (payload.comparisonTimestampSource) {
    metadata.comparison_timestamp_source = payload.comparisonTimestampSource;
  }
  if (payload.parserSource) metadata.parser_source = payload.parserSource;

  const values = {
    user_id: userId,
    source_payload_id: payload.payloadId,
    // Dedup alignment with the app's outbox push: the app imports this relay
    // capture with LOCAL id == payloadId and pushes it with
    // client_request_id == payloadId. Setting the same key here makes that
    // push hit the (user_id, client_request_id) unique index and UPDATE this
    // row instead of inserting a duplicate.
    client_request_id: payload.payloadId,
    amount: payload.amount,
    currency: payload.currency,
    direction: mapDirection(payload.direction, payload.type),
    transaction_type: mapTransactionType(payload.direction, payload.type),
    merchant: payload.merchant ?? null,
    category_id: payload.categoryId ?? null,
    occurred_at: payload.occurredAt,
    source: 'ios_shortcut',
    confidence: payload.confidence ?? null,
    status: payload.status ?? 'confirmed',
    balance_after: payload.balanceAfter ?? null,
    comparison_timestamp: payload.comparisonTimestamp ?? payload.occurredAt,
    comparison_timestamp_source: payload.comparisonTimestampSource ?? 'received_at',
    metadata,
  };

  const inserted = await supabase
    .from('user_transactions')
    .insert(values)
    .select('id')
    .maybeSingle();

  if (!inserted.error && inserted.data?.id) {
    return { id: inserted.data.id as string, created: true };
  }

  // A timed-out insert may have committed. Re-read by the stable source key;
  // never issue an update or generate a different idempotency key.
  if (inserted.error?.code === '23505') {
    const existing = await supabase
      .from('user_transactions')
      .select('id')
      .eq('user_id', userId)
      .eq('source_payload_id', payload.payloadId)
      .maybeSingle();
    if (!existing.error && existing.data?.id) {
      return { id: existing.data.id as string, created: false };
    }
    throw new Error('ledger_idempotency_read_failed');
  }

  throw new Error(`ledger_insert_failed: ${inserted.error?.message ?? 'unknown'}`);
}
