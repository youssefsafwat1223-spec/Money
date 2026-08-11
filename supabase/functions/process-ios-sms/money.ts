import { canonicalMoneyText, modelMoneyText } from '../_shared/money_text.ts';

export interface CaptureAmount {
  amount?: number;
  amount_text?: string;
}

export function extractCaptureAmount(
  text: string,
  patterns: string[],
  currency?: string,
): CaptureAmount {
  let token: string | undefined;
  for (const pattern of patterns) {
    const value = new RegExp(pattern, 'i').exec(text)?.[1]?.trim();
    if (value) {
      token = value;
      break;
    }
  }
  if (!token) return {};

  const legacyAmount = Number(token.replace(/,/g, ''));
  const amount = Number.isFinite(legacyAmount) ? legacyAmount : undefined;
  const amountText = currency ? canonicalMoneyText(token, currency) : null;
  return {
    ...(amount == null ? {} : { amount }),
    ...(amountText == null ? {} : { amount_text: amountText }),
  };
}

export function withValidatedModelAmountText(parsed: Record<string, unknown>): Record<string, unknown> {
  const next = { ...parsed };
  delete next.amount_text;
  const amountText = modelMoneyText(parsed);
  if (amountText != null) next.amount_text = amountText;
  return next;
}
