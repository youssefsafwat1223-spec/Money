// Time component of the capture duplicate fingerprint.
//
// sms_body timestamps stay exact: the bank's own timestamp disambiguates two
// genuinely distinct purchases with the same amount/merchant minutes apart.
//
// received_at timestamps get a tolerance window: when the SMS body carries no
// timestamp, a re-run of the same Shortcut (or a re-delivered automation)
// observes a slightly different receive time, and exact-equality fingerprints
// miss the duplicate entirely. Bucketing to 10 minutes and matching the
// current + previous bucket yields a ~10–20 minute detection window.

export const RECEIVED_AT_BUCKET_MS = 10 * 60 * 1000;

export function fingerprintTimeKeys(
  comparisonTimestamp: string,
  comparisonTimestampSource: string | undefined,
): string[] {
  if (comparisonTimestampSource === 'received_at') {
    const ms = new Date(comparisonTimestamp).getTime();
    if (Number.isFinite(ms)) {
      const bucket = Math.floor(ms / RECEIVED_AT_BUCKET_MS);
      return [`rb:${bucket}`, `rb:${bucket - 1}`];
    }
  }
  return [comparisonTimestamp];
}
