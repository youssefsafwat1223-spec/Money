const CURRENCY_MINOR_UNITS: Readonly<Record<string, number>> = {
  JPY: 0,
  EGP: 2,
  SAR: 2,
  AED: 2,
  USD: 2,
  EUR: 2,
  GBP: 2,
  QAR: 2,
  KWD: 3,
  BHD: 3,
  OMR: 3,
  JOD: 3,
};

export interface CanonicalMoneyTextOptions {
  allowNegative?: boolean;
}

/**
 * Validates a lexical decimal without parsing it through Number. Grouping is
 * accepted only in unambiguous 3-digit groups and is removed in the canonical
 * result. Fractional digits are preserved exactly; excess currency scale is
 * rejected rather than rounded.
 */
export function canonicalMoneyText(
  token: string,
  currency?: string,
  options: CanonicalMoneyTextOptions = {},
): string | null {
  if (!token || token.length > 256) return null;
  const match = /^(-?)(?:(0|[1-9][0-9]*)|([1-9][0-9]{0,2}(?:,[0-9]{3})+))(?:\.([0-9]+))?$/.exec(token);
  if (!match || (match[1] && !options.allowNegative)) return null;

  const fraction = match[4];
  const scale = currency ? CURRENCY_MINOR_UNITS[currency.trim().toUpperCase()] : undefined;
  if (scale != null && (fraction?.length ?? 0) > scale) return null;

  const integer = (match[2] ?? match[3]).replaceAll(',', '');
  const isZero = integer === '0' && (!fraction || /^0+$/.test(fraction));
  const sign = match[1] && !isZero ? '-' : '';
  return `${sign}${integer}${fraction == null ? '' : `.${fraction}`}`;
}

/**
 * Accepts exact model text only when it is valid for the currency and agrees
 * with the independently supplied legacy JSON number. The string is never
 * generated from that number.
 */
export function modelMoneyText(
  parsed: Record<string, unknown>,
  amountField = 'amount',
  textField = 'amount_text',
  currencyField = 'currency',
  options: CanonicalMoneyTextOptions = {},
): string | null {
  const token = parsed[textField];
  const currency = parsed[currencyField];
  const legacyAmount = parsed[amountField];
  if (typeof token !== 'string' || typeof currency !== 'string' || typeof legacyAmount !== 'number') return null;

  const canonical = canonicalMoneyText(token, currency, options);
  if (canonical == null || !Number.isFinite(legacyAmount) || Number(canonical) !== legacyAmount) return null;
  return canonical;
}

/** Revalidates exact fields already stored as strings. Never fills them from numbers. */
export function withValidatedExactMoneyText(parsed: Record<string, unknown>): Record<string, unknown> {
  const next = { ...parsed };
  const specs: Array<{
    textField: string;
    currencyField: string;
    allowNegative: boolean;
  }> = [
    { textField: 'amount_text', currencyField: 'currency', allowNegative: false },
    { textField: 'balance_after_text', currencyField: 'currency', allowNegative: true },
    { textField: 'foreign_amount_text', currencyField: 'foreign_currency', allowNegative: false },
  ];

  for (const spec of specs) {
    const token = next[spec.textField];
    if (token == null) continue;
    const currency = next[spec.currencyField];
    const canonical = typeof token === 'string' && typeof currency === 'string'
      ? canonicalMoneyText(token, currency, { allowNegative: spec.allowNegative })
      : null;
    if (canonical == null) delete next[spec.textField];
    else next[spec.textField] = canonical;
  }
  return next;
}
