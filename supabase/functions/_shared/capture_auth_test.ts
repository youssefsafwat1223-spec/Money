import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bumpCaptureEndpointRateLimit } from './capture_auth.ts';

Deno.test('bumpCaptureEndpointRateLimit namespaces endpoint keys', async () => {
  let params: Record<string, unknown> | undefined;
  const supabase = {
    rpc(_name: string, value: Record<string, unknown>) {
      params = value;
      return Promise.resolve({ data: false, error: null });
    },
  };

  const limited = await bumpCaptureEndpointRateLimit(
    supabase as never,
    'install-hash',
    'sync-captures',
    240,
  );

  assertEquals(limited, false);
  assertEquals(params, {
    p_install_id_hash: 'install-hash:sync-captures',
    p_limit: 240,
  });
});
