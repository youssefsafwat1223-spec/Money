// Deterministic, side-effect-free gate for an AI parse candidate (server twin of
// app/lib/engine/ai/ai_candidate_validator.dart). It never reads anything that
// resembles an AI confidence. The two implementations are pinned to each other
// by _shared/fixtures/ai_candidate_cases.json (run by BOTH test suites).
//
// Known, spec-mandated differences from the app (NOT covered by the shared
// fixtures, see ai_candidate_validator_test.ts):
//  - server additionally requires the AI currency to be on CURRENCY_CODES;
//  - server additionally rejects an AI `direction` field that contradicts the
//    message wording (the app only checks the normalized type);
//  - server additionally requires amount and amount_text to agree;
//  - amount_text must be ASCII-canonical (the app's parser also accepts
//    Arabic-Indic digits).
import { canonicalMoneyText } from './money_text.ts';

export const CURRENCY_CODES = ['SAR', 'AED', 'EGP', 'QAR', 'OMR', 'KWD', 'BHD', 'JOD', 'USD', 'EUR', 'GBP', 'JPY'];

export interface AiCandidate {
  amount?: number;
  amount_text?: string;
  currency?: string;
  merchant?: string;
  type?: string;
  direction?: string;
  category?: string;
  last4?: string;
  occurred_at?: string;
}

export interface LocalCandidate {
  amount: number;
  amount_text?: string;
  currency: string;
  direction?: string;
  merchant?: string;
}

export type AiCandidateValidation =
  | { accepted: false; reason: string }
  | {
    accepted: true;
    currency: string;
    /** Canonical exact amount text. */
    amountText: string;
    /** AI merchant when grounded, else the local one (or null). */
    merchant: string | null;
    /** AI date (ISO) when inside the plausibility window, else null. */
    occurredAt: string | null;
  };

const MAX_AGE_MS = 31 * 24 * 60 * 60 * 1000;
const MAX_FUTURE_MS = 24 * 60 * 60 * 1000;

// ── Direction wording (port of app DirectionSignal) ──────────────────────────
export type WordDirection = 'credit' | 'debit' | 'unknown';

const CREDIT_WORDS = [
  'إيداع',
  'ايداع',
  'أُضيف',
  'أضيف',
  'اضيف',
  'إضافة',
  'اضافة',
  'تم إضافة',
  'تم اضافة',
  'تم استلام',
  'استلمت',
  'استلام',
  'مبلغ وارد',
  'حوالة واردة',
  'راتب',
  'deposit',
  'salary',
  'credited',
  'received',
  'incoming',
  'استرداد',
  'مسترد',
  'مستردة',
  'رد مبلغ',
  'ردّ مبلغ',
  'إعادة مبلغ',
  'اعادة مبلغ',
  'عكس قيد',
  'عكس العملية',
  'refund',
  'refunded',
  'reversal',
  'reversed',
];
const DEBIT_WORDS = [
  'خصم',
  'خُصم',
  'تم الخصم',
  'شراء',
  'مشتريات',
  'دفع',
  'مدفوعات',
  'سحب',
  'مبلغ صادر',
  'صادر',
  'purchase',
  'payment',
  'paid',
  'debited',
  'withdrawn',
  'withdrawal',
  'deducted',
  'spent',
  'نقاط بيع',
];

export function directionOfWording(text: string): WordDirection {
  const lower = text.toLowerCase();
  const hasCredit = CREDIT_WORDS.some((w) => lower.includes(w));
  const hasDebit = DEBIT_WORDS.some((w) => lower.includes(w));
  if (hasCredit && !hasDebit) return 'credit';
  if (hasDebit && !hasCredit) return 'debit';
  return 'unknown';
}

export function directionOfType(type: string | undefined): WordDirection {
  switch (type) {
    case 'income':
    case 'refund':
      return 'credit';
    case 'payment':
    case 'withdrawal':
      return 'debit';
    default:
      return 'unknown';
  }
}

function asDirection(value: string | undefined): WordDirection {
  return value === 'credit' || value === 'debit' ? value : 'unknown';
}

function contradicts(wording: WordDirection, other: WordDirection): boolean {
  return wording !== 'unknown' && other !== 'unknown' && wording !== other;
}

/** True when an AI direction/type would contradict the message's own wording. */
export function directionContradictsWording(text: string, type?: string, direction?: string): boolean {
  const wording = directionOfWording(text);
  return contradicts(wording, directionOfType(type)) || contradicts(wording, asDirection(direction));
}

// ── Amount grounding (port of app GroundingCheck) ────────────────────────────
const ARABIC_DIGITS = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];

function toArabicIndic(s: string): string {
  return s.replace(/[0-9]/g, (d) => ARABIC_DIGITS[Number(d)]);
}

function group(plain: string): string {
  const dot = plain.indexOf('.');
  const integer = dot < 0 ? plain : plain.slice(0, dot);
  const fraction = dot < 0 ? '' : plain.slice(dot);
  if (integer.length <= 3) return plain;
  let out = '';
  for (let i = 0; i < integer.length; i++) {
    if (i > 0 && (integer.length - i) % 3 === 0) out += ',';
    out += integer[i];
  }
  return out + fraction;
}

export function amountGrounded(amount: unknown, text: string): boolean {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return false;
  const western = [amount.toFixed(2), amount.toFixed(3), amount.toFixed(1), amount.toFixed(0)];
  const all = new Set<string>(western);
  for (const w of western) all.add(toArabicIndic(w));
  for (const plain of western) {
    const grouped = group(plain);
    if (grouped === plain) continue;
    all.add(grouped);
    const arabic = toArabicIndic(grouped);
    all.add(arabic);
    all.add(arabic.replaceAll(',', '٬'));
    all.add(arabic.replaceAll(',', '٬').replaceAll('.', '٫'));
  }
  for (const c of all) if (text.includes(c)) return true;
  return false;
}

// ── Currency grounding (port of app Normalizer.normalizeCurrencyTokens) ──────
const CURRENCY_TOKEN_RULES: Array<[RegExp, string]> = [
  [/ر\.س\.?/gi, 'SAR'],
  [/ر\.ع\.?/gi, 'OMR'],
  [/ر\.ق\.?/gi, 'QAR'],
  [/د\.إ\.?/gi, 'AED'],
  [/د\.ك\.?/gi, 'KWD'],
  [/د\.ب\.?/gi, 'BHD'],
  [/ج\.م\.?/gi, 'EGP'],
  [/﷼/g, 'SAR'],
  [/ريال\s+سعودي/g, 'SAR'],
  [/ريال\s+قطري/g, 'QAR'],
  [/ريال\s+عماني/g, 'OMR'],
  [/درهم\s+إماراتي|درهم\s+اماراتي|درهم/g, 'AED'],
  [/جنيه\s+مصري|جنيه/g, 'EGP'],
  [/دينار\s+كويتي/g, 'KWD'],
  [/دينار\s+بحريني/g, 'BHD'],
  [/دولار\s+أمريكي|دولار\s+امريكي|دولار/g, 'USD'],
  [/ريال/g, 'SAR'],
];

const EXTRA_ALIASES: Record<string, string[]> = {
  USD: ['$'],
  EUR: ['€'],
  GBP: ['£'],
  JOD: ['دينار أردني', 'دينار اردني'],
};

export function normalizeCurrencyTokens(input: string): string {
  let out = input;
  for (const [re, to] of CURRENCY_TOKEN_RULES) out = out.replace(re, to);
  return out;
}

function currencyGrounded(iso: string, text: string): boolean {
  if (!iso) return false;
  const code = new RegExp(`(?<![A-Za-z])${iso}(?![A-Za-z])`, 'i');
  if (code.test(normalizeCurrencyTokens(text))) return true;
  return (EXTRA_ALIASES[iso] ?? []).some((a) => text.includes(a));
}

// ── Text grounding for merchant / last4 ──────────────────────────────────────
function collapse(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

export function merchantGrounded(merchant: string | undefined | null, text: string): boolean {
  if (typeof merchant !== 'string') return false;
  const needle = collapse(merchant);
  return needle.length > 0 && collapse(text).includes(needle);
}

export function last4Grounded(last4: string | undefined | null, text: string): boolean {
  return typeof last4 === 'string' && /^[0-9]{4}$/.test(last4) && text.includes(last4);
}

function inWindow(iso: string | undefined, receivedAt: string): string | null {
  if (typeof iso !== 'string' || !iso.trim()) return null;
  const clean = iso.trim();
  const zoned = /(?:z|[+-]\d{2}:?\d{2})$/i.test(clean) ? clean : `${clean}Z`;
  const at = new Date(zoned).getTime();
  const ref = new Date(receivedAt).getTime();
  if (Number.isNaN(at) || Number.isNaN(ref)) return null;
  const delta = at - ref;
  return delta >= -MAX_AGE_MS && delta <= MAX_FUTURE_MS ? new Date(at).toISOString() : null;
}

export function validateAiCandidate(input: {
  candidate: AiCandidate;
  sanitizedText: string;
  receivedAt: string;
  local: LocalCandidate | null;
}): AiCandidateValidation {
  const { candidate: c, sanitizedText: text, local } = input;
  const reject = (reason: string): AiCandidateValidation => ({ accepted: false, reason });

  if (!amountGrounded(c.amount, text)) return reject('amount_not_grounded');
  const amount = c.amount as number;
  const currency = (c.currency ?? '').trim().toUpperCase();
  if (local) {
    if (!(Math.abs(amount - local.amount) < 0.01)) return reject('amount_mismatch_local');
    if (currency !== local.currency.trim().toUpperCase()) return reject('currency_mismatch_local');
  } else {
    if (!CURRENCY_CODES.includes(currency)) return reject('currency_not_whitelisted');
    if (!currencyGrounded(currency, text)) return reject('currency_not_grounded');
  }

  if (typeof c.amount_text !== 'string') return reject('amount_text_missing');
  const amountText = canonicalMoneyText(c.amount_text, currency);
  if (amountText == null) return reject('amount_text_not_canonical');
  if (!(Math.abs(Number(amountText) - amount) < 0.01)) return reject('amount_text_mismatch');

  if (directionContradictsWording(text, c.type, c.direction)) return reject('direction_contradiction');

  const merchant = merchantGrounded(c.merchant, text) ? (c.merchant as string) : (local?.merchant ?? null);
  return {
    accepted: true,
    currency,
    amountText,
    merchant,
    occurredAt: inWindow(c.occurred_at, input.receivedAt),
  };
}
