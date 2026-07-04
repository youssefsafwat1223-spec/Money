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
    .select('value,value_type,is_active')
    .eq('key', key)
    .maybeSingle();

  let enabled =
    globalFlag?.is_active === true &&
    globalFlag?.value_type === 'boolean' &&
    String(globalFlag?.value).toLowerCase() === 'true';

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
