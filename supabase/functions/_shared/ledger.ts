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
    case 'credit': return 'income';
    case 'debit': return 'expense';
    default: return 'unknown';
  }
}

export async function upsertLedgerTransaction(
  supabase: ReturnType<typeof serviceClient>,
  userId: string,
  payload: LedgerWritePayload,
): Promise<void> {
  const { error } = await supabase.from('user_transactions').insert({
    user_id: userId,
    source_payload_id: payload.payloadId,
    amount: payload.amount,
    currency: payload.currency,
    direction: mapDirection(payload.direction, payload.type),
    transaction_type: mapTransactionType(payload.direction, payload.type),
    merchant: payload.merchant ?? null,
    category_id: payload.categoryId ?? null,
    occurred_at: payload.occurredAt,
    source: 'ios_shortcut',
    confidence: payload.confidence ?? null,
    metadata: payload.last4 ? { last4: payload.last4 } : {},
  });

  // 23505 = unique_violation → (user_id, source_payload_id) already exists → idempotent, ignore.
  if (error && error.code !== '23505') {
    throw new Error(`ledger_insert_failed: ${error.message}`);
  }
}
