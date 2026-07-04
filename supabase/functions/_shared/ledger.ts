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
}

export async function isLedgerDualWriteEnabled(
  supabase: ReturnType<typeof serviceClient>,
  userId: string | null,
): Promise<boolean> {
  return resolveUserBooleanFlag(supabase, 'ledger_dual_write', userId, {
    requireUser: true,
  });
}

// Approved type mapping (from process-ios-sms direction/type → ledger enum).
function mapLedgerType(
  direction?: string,
  type?: string,
): 'debit' | 'credit' | 'transfer' | 'unknown' {
  const d = (direction ?? '').toLowerCase();
  const t = (type ?? '').toLowerCase();
  const creditTerms = ['credit', 'income', 'deposit', 'received'];
  const debitTerms = ['debit', 'payment', 'purchase', 'withdrawal', 'charged', 'paid'];
  if (creditTerms.includes(d) || creditTerms.includes(t)) return 'credit';
  if (debitTerms.includes(d) || debitTerms.includes(t)) return 'debit';
  if (t === 'transfer' || d === 'transfer') return 'transfer';
  return 'unknown';
}

export async function upsertLedgerTransaction(
  supabase: ReturnType<typeof serviceClient>,
  userId: string,
  payload: LedgerWritePayload,
): Promise<void> {
  const { error } = await supabase.from('user_transactions').insert({
    user_id: userId,
    payload_id: payload.payloadId,
    amount: payload.amount,
    currency: payload.currency,
    type: mapLedgerType(payload.direction, payload.type),
    merchant: payload.merchant ?? null,
    category_id: payload.categoryId ?? null,
    occurred_at: payload.occurredAt,
    source: 'ios_shortcut',
    confidence: payload.confidence ?? null,
    metadata: payload.last4 ? { last4: payload.last4 } : {},
  });

  // 23505 = unique_violation → (user_id, payload_id) already exists → idempotent, ignore.
  if (error && error.code !== '23505') {
    throw new Error(`ledger_insert_failed: ${error.message}`);
  }
}
