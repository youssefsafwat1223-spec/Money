import { withValidatedExactMoneyText } from '../_shared/money_text.ts';

export function capturesForResponse(rows: unknown[]): unknown[] {
  return rows.map((row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return row;
    const capture = row as Record<string, unknown>;
    const parsed = capture.parsed;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return row;
    return { ...capture, parsed: withValidatedExactMoneyText(parsed as Record<string, unknown>) };
  });
}
