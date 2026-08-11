import { canonicalMoneyText, modelMoneyText } from '../_shared/money_text.ts';

export const PARSE_SMS_CURRENCY_CODES = [
  'EGP',
  'SAR',
  'AED',
  'USD',
  'EUR',
  'GBP',
  'KWD',
  'QAR',
  'BHD',
  'OMR',
  'JOD',
  'JPY',
];

export interface ExtractedAmount {
  amount: number;
  amount_text?: string;
  currency: string;
}

function extractedAmount(token: string, currency: string): ExtractedAmount {
  const amountText = canonicalMoneyText(token, currency);
  return {
    amount: Number(amountText ?? token.replace(/,/g, '')),
    ...(amountText == null ? {} : { amount_text: amountText }),
    currency,
  };
}

export function amountFromText(text: string): ExtractedAmount | null {
  const escapedCurrencies = PARSE_SMS_CURRENCY_CODES.join('|');
  const currencyBefore = new RegExp(`\\b(${escapedCurrencies})\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)`, 'i');
  const currencyAfter = new RegExp(`([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*\\b(${escapedCurrencies})\\b`, 'i');
  const egyptianPoundAfter = /([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:جم|جنيه)/i;
  const withAmountWord = new RegExp(
    `(?:amount(?:\\s+of)?|مبلغ)\\s*(?:of\\s*)?\\b(${escapedCurrencies})\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)`,
    'i',
  );
  const match = text.match(withAmountWord) ?? text.match(currencyBefore);
  if (match) return extractedAmount(match[2], match[1].toUpperCase());

  const reverse = text.match(currencyAfter);
  if (reverse) return extractedAmount(reverse[1], reverse[2].toUpperCase());

  const egp = text.match(egyptianPoundAfter);
  if (egp) return extractedAmount(egp[1], 'EGP');
  return null;
}

export function withValidatedModelAmountText(parsed: Record<string, unknown>): Record<string, unknown> {
  const next = { ...parsed };
  delete next.amount_text;
  const amountText = modelMoneyText(parsed);
  if (amountText != null) {
    next.amount_text = amountText;
    next.amount = Number(amountText);
  }
  return next;
}
