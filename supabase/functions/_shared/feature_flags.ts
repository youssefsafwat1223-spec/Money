import { serviceClient } from './capture_auth.ts';

export async function resolveUserBooleanFlag(
  supabase: ReturnType<typeof serviceClient>,
  key: string,
  userId: string | null,
  { requireUser = false }: { requireUser?: boolean } = {},
): Promise<boolean> {
  if (requireUser && !userId) return false;

  const { data: globalFlag } = await supabase
    .from('feature_flags')
    .select('value,value_type,is_active,rollout_percent,target_countries')
    .eq('key', key)
    .maybeSingle();

  let enabled = globalFlag?.is_active === true &&
    globalFlag?.value_type === 'boolean' &&
    String(globalFlag?.value).toLowerCase() === 'true';

  // C-10 — the client resolves a partial rollout by bucketing
  // SHA-256("<installId>:<key>") (data/catalog/feature_flag_service.dart), and
  // this resolver used to ignore `rollout_percent` entirely. The same flag could
  // therefore be off for 90% of clients while every Edge Function treated it as
  // fully on — which makes a "staged" rollout meaningless and is exactly the
  // wrong direction for a kill switch.
  //
  // The server cannot reproduce the client's cohort: the client buckets on
  // install_id and the server only knows user_id, so any bucketing here would
  // invent a DIFFERENT cohort rather than agree with the client. The honest
  // semantic is to fail closed — a partial rollout is not enabled server-side
  // until it reaches 100%. Conservative and predictable: the backend can never
  // enable a feature for more users than the staged client rollout intended.
  //
  // A per-user override still wins below: that is explicit operator intent about
  // one user, not a population estimate.
  const rollout = typeof globalFlag?.rollout_percent === 'number'
    ? globalFlag.rollout_percent
    : 100;
  if (enabled && rollout < 100) enabled = false;

  // Same reasoning for country targeting: this resolver has no country context,
  // so a targeted flag cannot be evaluated here and must not be assumed global.
  const targets = globalFlag?.target_countries;
  if (enabled && Array.isArray(targets) && targets.length > 0) enabled = false;

  if (!userId) return enabled;

  const { data: override } = await supabase
    .from('feature_flag_overrides')
    .select('enabled')
    .eq('user_id', userId)
    .eq('key', key)
    .maybeSingle();

  if (typeof override?.enabled === 'boolean') {
    enabled = override.enabled;
  }
  return enabled;
}
